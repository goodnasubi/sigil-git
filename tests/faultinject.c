// 障害注入ランナー（ADR 0047 決定 6-5、Issue #634）。Linux x86_64 専用。
//
// ptrace で対象プロセスの「ファイルシステムを変更する syscall」に通し番号（ステップ）を付け、指定したステップで
// 決定論的に障害を起こす。対象のバイナリは静的リンクなので LD_PRELOAD は使えず、本体のコードにも手を入れない。
// root 権限は要らない（自分の子プロセスを追跡するだけ）。
//
// 使い方: faultinject [-l LOG] [-d DURABLE] [-m MODE] [-n N] [-e ERRNO] [-b BYTES] [-s] -- COMMAND [ARGS...]
//   -m count        何も起こさず、ステップ表を LOG に書く（既定）
//   -m kill-before  N 番目のステップの実行前に SIGKILL する
//   -m kill-after   N 番目のステップが終わった直後に SIGKILL する
//   -m error        N 番目のステップを実行せず、-e の errno（EIO・ENOSPC など）で失敗させる。-s なら N 番目以降すべて
//   -m short        N 番目の write/pwrite64 の長さを -b バイトに縮める（カーネルが本当に短く書き、短い戻り値を返す）
//   -d DURABLE      終了時に「同期されていないデータを持つファイル」の一覧（パス・同期済みの長さ）を書く。
//                   電源断の模擬（未同期のデータを捨てる）に使う
// ステップの種類: ファイルの作成・書き込み用 open（open/openat/openat2/creat）、write/pwrite64/writev/pwritev/pwritev2、
//   fsync/fdatasync、rename、unlink、mkdir、rmdir、ftruncate/truncate、fchmod/chmod/fchmodat
//   （fd 0〜2 への write、通常ファイルとディレクトリ以外（/dev/null・パイプなど）は数えない）。
// 持続性の記録（-d）は syscall の「出口」で、成功したときだけ更新する。fsync の直前で止めたとき、fsync が失敗したときに、
//   データを同期済みと誤認しないため。
// 終了状態: 子の終了コード。シグナルで死んだときは 128 + シグナル番号。

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/user.h>
#include <sys/wait.h>
#include <unistd.h>

#if !defined(__x86_64__) || !defined(__linux__)
#error "faultinject.c supports Linux x86_64 only"
#endif

enum mode { M_COUNT, M_KILL_BEFORE, M_KILL_AFTER, M_ERROR, M_SHORT };

static enum mode g_mode = M_COUNT;
static long g_n = 0;
static int g_errno = EIO;
static long g_bytes = 1;
static int g_sticky = 0;
static FILE *g_log = NULL;
static const char *g_durable_path = NULL;

// 追跡中のプロセスごとの状態
struct task {
  pid_t pid;
  int in_syscall;       // 0: 次は入口、1: 次は出口
  int counted;          // 今の syscall がステップとして数えられたか
  long step;            // 今の syscall のステップ番号
  int inject_error;     // 入口で syscall を飛ばし、出口で errno を返す
  int kill_after_this;  // 出口で SIGKILL
  char saved_a[PATH_MAX];  // rename の旧パス（絶対）
  char saved_b[PATH_MAX];  // rename の新パス（絶対）
  int open_write;       // 書き込み用 open か
  int open_trunc;       // O_TRUNC か
  int open_creat;       // O_CREAT か
  int open_existed;     // open の入口で、すでに通常ファイルとして存在したか
  long open_size;       // open の入口での大きさ（existed のとき）
  int op;               // 出口で記録する持続性の操作（OP_*）
  char p1[PATH_MAX];    // 持続性の操作の対象パス（絶対）
};
enum { OP_NONE = 0, OP_WRITE, OP_TRUNCATE, OP_SYNC, OP_UNLINK };
#define MAX_TASKS 64
static struct task tasks[MAX_TASKS];
static int ntasks = 0;
static long g_step = 0;

// 同期されていないデータを持つファイルの記録
struct dirty {
  char path[PATH_MAX];
  long synced_len;
  int dirty;
  int live;
};
#define MAX_DIRTY 4096
static struct dirty dirties[MAX_DIRTY];
static int ndirty = 0;

static struct task *find_task(pid_t pid) {
  for (int i = 0; i < ntasks; i++)
    if (tasks[i].pid == pid) return &tasks[i];
  return NULL;
}

// 空いた（終了した）スロットを再利用する。使い切ったら黙って追跡をやめず、その場で異常終了する（見逃しを防ぐ）。
static struct task *add_task(pid_t pid) {
  struct task *t = find_task(pid);
  if (t) return t;
  int slot = -1;
  for (int i = 0; i < ntasks; i++)
    if (tasks[i].pid == 0) { slot = i; break; }
  if (slot < 0) {
    if (ntasks >= MAX_TASKS) {
      fprintf(stderr, "faultinject: more than %d live tasks; the tracer cannot follow them\n", MAX_TASKS);
      _exit(3);  // PTRACE_O_EXITKILL で子も終わる
    }
    slot = ntasks++;
  }
  t = &tasks[slot];
  memset(t, 0, sizeof(*t));
  t->pid = pid;
  return t;
}

static int read_tracee_string(pid_t pid, unsigned long addr, char *buf, size_t cap) {
  size_t i = 0;
  while (i + 1 < cap) {
    errno = 0;
    long w = ptrace(PTRACE_PEEKDATA, pid, (void *)(addr + i), NULL);
    if (errno != 0) return -1;
    for (size_t k = 0; k < sizeof(long) && i + 1 < cap; k++) {
      char c = (char)((w >> (8 * k)) & 0xff);
      buf[i++] = c;
      if (c == '\0') return 0;
    }
  }
  buf[cap - 1] = '\0';
  return 0;
}

static int fd_path(pid_t pid, int fd, char *buf, size_t cap) {
  char link[64];
  snprintf(link, sizeof link, "/proc/%d/fd/%d", pid, fd);
  ssize_t n = readlink(link, buf, cap - 1);
  if (n < 0) return -1;
  buf[n] = '\0';
  return 0;
}

// dirfd と文字列から絶対パスを作る（. や .. の正規化まではしない。ここでは前置きの結合だけ）
static void abs_path(pid_t pid, long dirfd, const char *s, char *out, size_t cap) {
  if (s[0] == '/') {
    snprintf(out, cap, "%s", s);
    return;
  }
  char base[PATH_MAX];
  if ((int)dirfd == AT_FDCWD) {
    char link[64];
    snprintf(link, sizeof link, "/proc/%d/cwd", pid);
    ssize_t n = readlink(link, base, sizeof base - 1);
    if (n < 0) n = 0;
    base[n] = '\0';
  } else if (fd_path(pid, (int)dirfd, base, sizeof base) != 0) {
    base[0] = '\0';
  }
  snprintf(out, cap, "%s/%s", base, s);
}

static struct dirty *dirty_find(const char *path, int create) {
  for (int i = 0; i < ndirty; i++)
    if (dirties[i].live && strcmp(dirties[i].path, path) == 0) return &dirties[i];
  if (!create || ndirty >= MAX_DIRTY) return NULL;
  struct dirty *d = &dirties[ndirty++];
  memset(d, 0, sizeof *d);
  snprintf(d->path, sizeof d->path, "%s", path);
  d->live = 1;
  return d;
}

// 書き込みがあった。追跡に載っていなければ、新しく作ったファイルとして同期済みの長さ 0 で載せる。
static void dirty_mark_keep(const char *path) {
  struct dirty *d = dirty_find(path, 1);
  if (d) d->dirty = 1;
}

static void dirty_sync(const char *path) {
  struct stat st;
  struct dirty *d = dirty_find(path, 1);
  if (!d) return;
  d->dirty = 0;
  d->synced_len = (stat(path, &st) == 0) ? (long)st.st_size : 0;
}

// 書き込み用に open した既存ファイルを、同期済みの長さ size で追跡に載せる（まだ載っていなければ）。
static void dirty_baseline(const char *path, long size) {
  if (dirty_find(path, 0)) return;
  struct dirty *d = dirty_find(path, 1);
  if (d) { d->dirty = 0; d->synced_len = size; }
}

static void dirty_forget(const char *path) {
  struct dirty *d = dirty_find(path, 0);
  if (d) d->live = 0;
}

static void dirty_rename(const char *from, const char *to) {
  struct dirty *src = dirty_find(from, 0);
  dirty_forget(to);
  if (!src) return;
  struct dirty *dst = dirty_find(to, 1);
  if (!dst) return;
  dst->dirty = src->dirty;
  dst->synced_len = src->synced_len;
  src->live = 0;
}

static void write_durable(void) {
  if (!g_durable_path) return;
  FILE *f = fopen(g_durable_path, "w");
  if (!f) return;
  for (int i = 0; i < ndirty; i++) {
    if (dirties[i].live && dirties[i].dirty && access(dirties[i].path, F_OK) == 0)
      fprintf(f, "%ld\t%s\n", dirties[i].synced_len, dirties[i].path);
  }
  fclose(f);
}

static const char *sysname(long nr) {
  switch (nr) {
    case SYS_open: case SYS_openat: case SYS_openat2: case SYS_creat: return "open";
    case SYS_write: return "write";
    case SYS_pwrite64: return "pwrite";
    case SYS_writev: return "writev";
    case SYS_pwritev: case SYS_pwritev2: return "pwritev";
    case SYS_fsync: return "fsync";
    case SYS_fdatasync: return "fdatasync";
    case SYS_rename: case SYS_renameat: case SYS_renameat2: return "rename";
    case SYS_unlink: case SYS_unlinkat: return "unlink";
    case SYS_mkdir: case SYS_mkdirat: return "mkdir";
    case SYS_rmdir: return "rmdir";
    case SYS_ftruncate: case SYS_truncate: return "ftruncate";
    case SYS_fchmod: case SYS_chmod: case SYS_fchmodat: return "fchmod";
    default: return NULL;
  }
}

// 入口で呼ぶ。ステップなら番号を付けて処理する。
static void on_entry(struct task *t, struct user_regs_struct *r) {
  long nr = (long)r->orig_rax;
  const char *name = sysname(nr);
  t->counted = 0;
  t->saved_a[0] = '\0';
  t->inject_error = 0;
  t->kill_after_this = 0;
  t->open_write = 0;
  t->open_trunc = 0;
  t->open_creat = 0;
  t->open_existed = 0;
  t->open_size = 0;
  t->op = OP_NONE;
  t->p1[0] = '\0';
  if (!name) return;
  char detail[PATH_MAX + 64] = "";
  char p1[PATH_MAX] = "";
  int is_step = 1;
  switch (nr) {
    case SYS_open: case SYS_openat: case SYS_openat2: case SYS_creat: {
      long flags, dirfd = AT_FDCWD;
      unsigned long pathaddr;
      if (nr == SYS_open) { pathaddr = r->rdi; flags = (long)r->rsi; }
      else if (nr == SYS_creat) { pathaddr = r->rdi; flags = O_CREAT | O_WRONLY | O_TRUNC; }
      else if (nr == SYS_openat2) {
        // struct open_how { u64 flags; u64 mode; u64 resolve; } の flags を読む
        dirfd = (long)r->rdi; pathaddr = r->rsi;
        errno = 0;
        long w = ptrace(PTRACE_PEEKDATA, t->pid, (void *)r->rdx, NULL);
        flags = (errno == 0) ? w : 0;
      }
      else { dirfd = (long)r->rdi; pathaddr = r->rsi; flags = (long)r->rdx; }
      if (!(flags & (O_CREAT | O_WRONLY | O_RDWR | O_TRUNC))) { is_step = 0; break; }
      char s[PATH_MAX] = "";
      read_tracee_string(t->pid, pathaddr, s, sizeof s);
      abs_path(t->pid, dirfd, s, p1, sizeof p1);
      struct stat st;
      int exists = (stat(p1, &st) == 0);
      if (exists && !S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)) { is_step = 0; break; }  // /dev/null など
      t->open_write = 1;
      t->open_trunc = (flags & O_TRUNC) != 0;
      t->open_creat = (flags & O_CREAT) != 0;
      t->open_existed = exists && S_ISREG(st.st_mode);
      t->open_size = t->open_existed ? (long)st.st_size : 0;
      snprintf(detail, sizeof detail, "%s%s%s", (flags & O_EXCL) ? "excl " : "", (flags & O_CREAT) ? "create " : "", s);
      break;
    }
    case SYS_write: case SYS_pwrite64: case SYS_writev: case SYS_pwritev: case SYS_pwritev2:
    case SYS_fsync: case SYS_fdatasync: case SYS_ftruncate: case SYS_fchmod: {
      int fd = (int)r->rdi;
      if (fd < 3) { is_step = 0; break; }
      if (fd_path(t->pid, fd, p1, sizeof p1) != 0 || p1[0] != '/') { is_step = 0; break; }
      struct stat st;
      int known = (stat(p1, &st) == 0);
      if (known && !S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)) { is_step = 0; break; }  // /dev/null など
      int isdir = known && S_ISDIR(st.st_mode);
      snprintf(detail, sizeof detail, "%s%s", isdir ? "dir " : "", p1);
      if (nr == SYS_write || nr == SYS_pwrite64) snprintf(detail + strlen(detail), 40, " len=%lu", (unsigned long)r->rdx);
      break;
    }
    case SYS_truncate: case SYS_chmod: case SYS_fchmodat: {
      long dirfd = AT_FDCWD;
      unsigned long pa;
      if (nr == SYS_fchmodat) { dirfd = (long)r->rdi; pa = r->rsi; }
      else pa = r->rdi;
      char s[PATH_MAX] = "";
      read_tracee_string(t->pid, pa, s, sizeof s);
      abs_path(t->pid, dirfd, s, p1, sizeof p1);
      snprintf(detail, sizeof detail, "%s", s);
      break;
    }
    case SYS_rename: case SYS_renameat: case SYS_renameat2: {
      long od = AT_FDCWD, nd = AT_FDCWD;
      unsigned long oa, na;
      if (nr == SYS_rename) { oa = r->rdi; na = r->rsi; }
      else { od = (long)r->rdi; oa = r->rsi; nd = (long)r->rdx; na = r->r10; }
      char a[PATH_MAX] = "", b[PATH_MAX] = "";
      read_tracee_string(t->pid, oa, a, sizeof a);
      read_tracee_string(t->pid, na, b, sizeof b);
      abs_path(t->pid, od, a, t->saved_a, sizeof t->saved_a);
      abs_path(t->pid, nd, b, t->saved_b, sizeof t->saved_b);
      snprintf(detail, sizeof detail, "%s -> %s", a, b);
      break;
    }
    case SYS_unlink: case SYS_unlinkat: case SYS_mkdir: case SYS_mkdirat: case SYS_rmdir: {
      long dirfd = AT_FDCWD;
      unsigned long pa;
      if (nr == SYS_unlink || nr == SYS_mkdir || nr == SYS_rmdir) pa = r->rdi;
      else { dirfd = (long)r->rdi; pa = r->rsi; }
      char s[PATH_MAX] = "";
      read_tracee_string(t->pid, pa, s, sizeof s);
      abs_path(t->pid, dirfd, s, p1, sizeof p1);
      snprintf(detail, sizeof detail, "%s", s);
      break;
    }
    default:
      is_step = 0;
  }
  if (!is_step) return;
  t->counted = 1;
  t->step = ++g_step;
  if (g_log) {
    fprintf(g_log, "%ld\t%s\t%s\n", t->step, name, detail);
    fflush(g_log);
  }
  // 持続性の追跡: 対象を覚えておき、出口で、成功したときだけ記録する（実行されなかった・失敗した syscall では状態を変えない）
  snprintf(t->p1, sizeof t->p1, "%s", p1);
  if (nr == SYS_write || nr == SYS_pwrite64 || nr == SYS_writev || nr == SYS_pwritev || nr == SYS_pwritev2) t->op = OP_WRITE;
  else if (nr == SYS_ftruncate || nr == SYS_truncate) t->op = OP_TRUNCATE;
  else if (nr == SYS_fsync || nr == SYS_fdatasync) t->op = OP_SYNC;
  else if (nr == SYS_unlink || nr == SYS_unlinkat) t->op = OP_UNLINK;
  // 障害の注入
  int hit = (g_n > 0) && (t->step == g_n || (g_sticky && g_mode == M_ERROR && t->step > g_n));
  if (!hit) return;
  if (g_mode == M_KILL_BEFORE && t->step == g_n) {
    kill(t->pid, SIGKILL);
  } else if (g_mode == M_KILL_AFTER && t->step == g_n) {
    t->kill_after_this = 1;
  } else if (g_mode == M_ERROR) {
    r->orig_rax = (unsigned long long)-1;  // syscall を飛ばす
    ptrace(PTRACE_SETREGS, t->pid, NULL, r);
    t->inject_error = 1;
    if (g_log) {
      fprintf(g_log, "# step %ld failed with errno %d\n", t->step, g_errno);
      fflush(g_log);
    }
  } else if (g_mode == M_SHORT && (nr == SYS_write || nr == SYS_pwrite64) && t->step == g_n) {
    if ((long)r->rdx > g_bytes) {
      r->rdx = (unsigned long long)g_bytes;  // カーネルが本当に短く書く
      ptrace(PTRACE_SETREGS, t->pid, NULL, r);
      if (g_log) {
        fprintf(g_log, "# step %ld shortened to %ld bytes\n", t->step, g_bytes);
        fflush(g_log);
      }
    }
  }
}

// 出口で呼ぶ。
static void on_exit_stop(struct task *t, struct user_regs_struct *r) {
  if (t->inject_error) {
    r->rax = (unsigned long long)(-(long)g_errno);
    ptrace(PTRACE_SETREGS, t->pid, NULL, r);
    t->inject_error = 0;
    return;
  }
  if (!t->counted) return;
  long ret = (long)r->rax;
  // 持続性の記録（出口で、戻り値が成功のときだけ）
  if (t->open_write && ret >= 0) {
    char p[PATH_MAX];
    if (fd_path(t->pid, (int)ret, p, sizeof p) == 0 && p[0] == '/') {
      if (t->open_trunc || (t->open_creat && !t->open_existed)) {
        // 切り詰めた、または新しく作った: 内容はまだ同期されていない
        struct dirty *d = dirty_find(p, 1);
        if (d) { d->dirty = 1; d->synced_len = 0; }
      } else if (t->open_existed) {
        // 既存のファイルをそのまま開いた: もとの大きさまでは耐久とみなす
        dirty_baseline(p, t->open_size);
      }
    }
  }
  if (t->op == OP_WRITE && ret > 0) dirty_mark_keep(t->p1);
  else if (t->op == OP_TRUNCATE && ret == 0) dirty_mark_keep(t->p1);
  else if (t->op == OP_SYNC && ret == 0) dirty_sync(t->p1);
  else if (t->op == OP_UNLINK && ret == 0) dirty_forget(t->p1);
  t->op = OP_NONE;
  // rename は出口で成功したときだけ状態を移す（入口では nr を見ているので syscall 番号は orig_rax に残らないことがある）
  if (t->saved_a[0] && ret >= 0) {
    dirty_rename(t->saved_a, t->saved_b);
  }
  t->saved_a[0] = '\0';
  if (t->kill_after_this) {
    kill(t->pid, SIGKILL);
    t->kill_after_this = 0;
  }
}

static int usage(void) {
  fprintf(stderr, "usage: faultinject [-l LOG] [-d DURABLE] [-m count|kill-before|kill-after|error|short] [-n N] [-e ERRNO] [-b BYTES] [-s] -- cmd...\n");
  return 2;
}

static int parse_errno(const char *s) {
  if (!strcmp(s, "EIO")) return EIO;
  if (!strcmp(s, "ENOSPC")) return ENOSPC;
  if (!strcmp(s, "EDQUOT")) return EDQUOT;
  if (!strcmp(s, "EROFS")) return EROFS;
  if (!strcmp(s, "EINTR")) return EINTR;
  return atoi(s);
}

int main(int argc, char **argv) {
  int i = 1;
  for (; i < argc; i++) {
    if (!strcmp(argv[i], "--")) { i++; break; }
    if (!strcmp(argv[i], "-s")) { g_sticky = 1; continue; }
    if (i + 1 >= argc) return usage();
    if (!strcmp(argv[i], "-l")) { g_log = fopen(argv[++i], "w"); if (!g_log) { perror("log"); return 2; } }
    else if (!strcmp(argv[i], "-d")) g_durable_path = argv[++i];
    else if (!strcmp(argv[i], "-n")) g_n = atol(argv[++i]);
    else if (!strcmp(argv[i], "-e")) g_errno = parse_errno(argv[++i]);
    else if (!strcmp(argv[i], "-b")) g_bytes = atol(argv[++i]);
    else if (!strcmp(argv[i], "-m")) {
      const char *m = argv[++i];
      if (!strcmp(m, "count")) g_mode = M_COUNT;
      else if (!strcmp(m, "kill-before")) g_mode = M_KILL_BEFORE;
      else if (!strcmp(m, "kill-after")) g_mode = M_KILL_AFTER;
      else if (!strcmp(m, "error")) g_mode = M_ERROR;
      else if (!strcmp(m, "short")) g_mode = M_SHORT;
      else return usage();
    } else return usage();
  }
  if (i >= argc) return usage();

  pid_t child = fork();
  if (child < 0) { perror("fork"); return 2; }
  if (child == 0) {
    if (ptrace(PTRACE_TRACEME, 0, NULL, NULL) != 0) { perror("PTRACE_TRACEME"); _exit(126); }
    raise(SIGSTOP);
    execvp(argv[i], &argv[i]);
    perror("execvp");
    _exit(127);
  }
  int status;
  if (waitpid(child, &status, 0) < 0) { perror("waitpid"); return 2; }
  long opts = PTRACE_O_TRACESYSGOOD | PTRACE_O_TRACECLONE | PTRACE_O_TRACEFORK | PTRACE_O_TRACEVFORK | PTRACE_O_TRACEEXEC | PTRACE_O_EXITKILL;
  ptrace(PTRACE_SETOPTIONS, child, NULL, (void *)opts);
  add_task(child);
  ptrace(PTRACE_SYSCALL, child, NULL, NULL);

  int exit_code = 0;
  int alive = 1;
  while (alive > 0) {
    pid_t pid = waitpid(-1, &status, __WALL);
    if (pid < 0) {
      if (errno == EINTR) continue;
      break;
    }
    struct task *t = find_task(pid);
    if (WIFEXITED(status) || WIFSIGNALED(status)) {
      if (pid == child) exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
      if (t) t->pid = 0;
      int any = 0;
      for (int k = 0; k < ntasks; k++) if (tasks[k].pid) any = 1;
      if (!any) alive = 0;
      continue;
    }
    if (!WIFSTOPPED(status)) continue;
    if (!t) t = add_task(pid);
    int sig = WSTOPSIG(status);
    int deliver = 0;
    if (sig == (SIGTRAP | 0x80)) {
      struct user_regs_struct regs;
      if (ptrace(PTRACE_GETREGS, pid, NULL, &regs) == 0 && t) {
        if (!t->in_syscall) { on_entry(t, &regs); t->in_syscall = 1; }
        else { on_exit_stop(t, &regs); t->in_syscall = 0; }
      }
    } else if (sig == SIGTRAP) {
      int ev = status >> 16;
      if (ev == PTRACE_EVENT_CLONE || ev == PTRACE_EVENT_FORK || ev == PTRACE_EVENT_VFORK) {
        unsigned long np = 0;
        ptrace(PTRACE_GETEVENTMSG, pid, NULL, &np);
        add_task((pid_t)np);
      }
      // PTRACE_EVENT_EXEC: execve の完了。syscall の入口・出口の組は変わらないので、ここでは何もしない
    } else if (sig == SIGSTOP && t && t->in_syscall == 0 && t->step == 0 && pid != child) {
      deliver = 0;  // 新しいタスクの最初の停止
    } else {
      deliver = sig;
    }
    ptrace(PTRACE_SYSCALL, pid, NULL, (void *)(long)deliver);
  }
  write_durable();
  if (g_log) fclose(g_log);
  return exit_code;
}
