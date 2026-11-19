// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

// C ABI harness for libsinglink (App F-02 and F-01, VPN Labs follow-up).
//
// Built and run by core/ffi/cabi_test.go: it loads the freshly built
// c-shared library with dlopen, checks every export against the prototypes
// of the generated libsinglink.h, and drives SingLinkTunStart /
// SingLinkTunStop / SingLinkStop / SingLinkStart through the real C ABI with
// real pipe descriptors as TUN stand-ins, the way the Android bridge and the
// Apple packet tunnel call them.
//
// For every path it checks the process descriptor table (fstat over every
// descriptor number): the caller's descriptor stays open and unchanged at
// its number, the core's duplicate is close-on-exec while it exists and is
// gone after the call (failure) or after the stop / TUN failure (success),
// and sentinel descriptors opened before the core was used are untouched.
//
// Inputs (environment): SL_LINK_OK (synthetic loopback node),
// SL_LINK_CLOSED (nothing listens), SL_LINK_SILENT (accepts, never answers),
// SL_LIB (path of the library). Prints "ok - ..." / "not ok - ..." lines and
// exits non-zero on any failure.

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "libsinglink.h"

static __typeof__(&SingLinkTunStart) pTunStart;
static __typeof__(&SingLinkTunStop) pTunStop;
static __typeof__(&SingLinkStart) pStart;
static __typeof__(&SingLinkStop) pStop;
static __typeof__(&SingLinkStatus) pStatus;
static __typeof__(&SingLinkFree) pFree;

static int failures;

#define CHECK(cond, ...)                                     \
  do {                                                       \
    if (!(cond)) {                                           \
      failures++;                                            \
      printf("not ok - %s:%d: ", __func__, __LINE__);        \
      printf(__VA_ARGS__);                                   \
      printf("\n");                                          \
      fflush(stdout);                                        \
    }                                                        \
  } while (0)

static void pass(const char *name) {
  printf("ok - %s\n", name);
  fflush(stdout);
}

// ---- descriptor table -----------------------------------------------------

#define MAXFD 4096

typedef struct {
  dev_t dev;
  ino_t ino;
} ident;

static int ident_of(int fd, ident *out) {
  struct stat st;
  if (fstat(fd, &st) != 0) return -1;
  out->dev = st.st_dev;
  out->ino = st.st_ino;
  return 0;
}

static int same(ident a, ident b) { return a.dev == b.dev && a.ino == b.ino; }

static int refs(ident id) {
  int n = 0;
  for (int fd = 0; fd < MAXFD; fd++) {
    ident cur;
    if (ident_of(fd, &cur) == 0 && same(cur, id)) n++;
  }
  return n;
}

// A descriptor other than [except1]/[except2] referring to [id], or -1.
static int other_ref(ident id, int except1, int except2) {
  for (int fd = 0; fd < MAXFD; fd++) {
    ident cur;
    if (fd == except1 || fd == except2) continue;
    if (ident_of(fd, &cur) == 0 && same(cur, id)) return fd;
  }
  return -1;
}

static void sleep_ms(int ms) {
  struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
}

// Waits up to 5 s for refs(id) to reach [want]; returns the last count.
static int wait_refs(ident id, int want) {
  int n = refs(id);
  for (int i = 0; i < 500 && n != want; i++) {
    sleep_ms(10);
    n = refs(id);
  }
  return n;
}

// ---- sentinels --------------------------------------------------------------

#define NSENT 4
static int sentinel_fd[NSENT];
static ident sentinel_id[NSENT];

static void open_sentinels(void) {
  int p[2];
  if (pipe(p) != 0) abort();
  sentinel_fd[0] = p[0];
  sentinel_fd[1] = p[1];
  sentinel_fd[2] = open("/dev/null", O_RDONLY);
  sentinel_fd[3] = open("/dev/null", O_WRONLY);
  for (int i = 0; i < NSENT; i++) {
    if (sentinel_fd[i] < 0 || ident_of(sentinel_fd[i], &sentinel_id[i]) != 0) abort();
  }
}

static void check_sentinels(const char *when) {
  for (int i = 0; i < NSENT; i++) {
    ident cur;
    CHECK(ident_of(sentinel_fd[i], &cur) == 0 && same(cur, sentinel_id[i]),
          "%s: unrelated descriptor %d was closed or replaced", when, sentinel_fd[i]);
  }
}

// ---- replies ----------------------------------------------------------------

typedef struct {
  int ok;
  char text[2048];
} reply;

static reply take(char *raw) {
  reply r = {0, ""};
  if (raw == NULL) {
    snprintf(r.text, sizeof r.text, "(NULL)");
    return r;
  }
  snprintf(r.text, sizeof r.text, "%s", raw);
  r.ok = strstr(raw, "\"ok\":true") != NULL;
  pFree(raw);
  return r;
}

// Copies the string value of "key" from a reply into out; 0 on success.
static int field(const reply *r, const char *key, char *out, size_t n) {
  char pat[64];
  snprintf(pat, sizeof pat, "\"%s\":\"", key);
  const char *s = strstr(r->text, pat);
  if (s == NULL) return -1;
  s += strlen(pat);
  const char *e = strchr(s, '"');
  if (e == NULL || (size_t)(e - s) >= n) return -1;
  memcpy(out, s, (size_t)(e - s));
  out[e - s] = 0;
  return 0;
}

static int running(void) {
  reply r = take(pStatus());
  return strstr(r.text, "\"running\":true") != NULL;
}

static const char *env(const char *name) {
  const char *v = getenv(name);
  if (v == NULL || *v == 0) {
    fprintf(stderr, "missing %s\n", name);
    exit(2);
  }
  return v;
}

static char *tun_config(const char *link) {
  static char buf[8192];
  snprintf(buf, sizeof buf,
           "{\"link\":\"%s\",\"mtu\":1500,\"dns\":\"192.0.2.53:53\",\"appleHeader\":false}", link);
  return buf;
}

// ---- TUN cases --------------------------------------------------------------

typedef struct {
  int r, w;
  ident id;
  int base;  // references to the read end before the core saw it
} tunfd;

static tunfd new_tun(void) {
  tunfd t;
  int p[2];
  if (pipe(p) != 0) abort();
  t.r = p[0];
  t.w = p[1];
  if (ident_of(t.r, &t.id) != 0) abort();
  t.base = refs(t.id);  // 1, or 2 where the write end shares the identity
  return t;
}

// The caller's descriptor is still open, unchanged, and is the caller's to
// close exactly once; afterwards no copy of it is left anywhere.
static void finish_caller(tunfd *t, const char *name) {
  ident cur;
  CHECK(ident_of(t->r, &cur) == 0 && same(cur, t->id), "%s: caller's descriptor %d was closed or replaced", name, t->r);
  CHECK(wait_refs(t->id, t->base) == t->base, "%s: %d references after the call, want %d (duplicate leaked)", name,
        refs(t->id), t->base);
  CHECK(close(t->r) == 0, "%s: caller's single close failed: %s (closed by the core?)", name, strerror(errno));
  CHECK(refs(t->id) == t->base - 1, "%s: a copy of the descriptor survived the caller's close", name);
  close(t->w);
  check_sentinels(name);
}

static void expect_failed_start(const char *name, int fd_is_valid, const char *config) {
  tunfd t = new_tun();
  int fd = fd_is_valid ? t.r : -1;
  reply r = take(pTunStart(fd, (char *)config));
  CHECK(!r.ok, "%s: start unexpectedly succeeded: %s", name, r.text);
  CHECK(strstr(r.text, "\"error\":\"") != NULL, "%s: failure without an error text: %s", name, r.text);
  finish_caller(&t, name);
  pass(name);
}

static void case_closed_descriptor_number(void) {
  int fd = -1;
  for (int n = 900; n < 1000; n++) {
    ident cur;
    if (ident_of(n, &cur) != 0) {
      fd = n;
      break;
    }
  }
  CHECK(fd >= 0, "no free descriptor number");
  reply r = take(pTunStart(fd, tun_config(env("SL_LINK_CLOSED"))));
  CHECK(!r.ok, "a closed descriptor number was accepted: %s", r.text);
  CHECK(strstr(r.text, "duplicate") != NULL, "unexpected error for a closed descriptor: %s", r.text);
  check_sentinels("closed descriptor");
  pass("SingLinkTunStart rejects a descriptor number that is not open");
}

typedef enum { STOP_TUN, STOP_ENGINE, STOP_TUN_FAILURE } stop_kind;

static void case_success(stop_kind how, const char *name) {
  tunfd t = new_tun();
  reply r = take(pTunStart(t.r, tun_config(env("SL_LINK_OK"))));
  CHECK(r.ok, "%s: start failed: %s", name, r.text);
  if (!r.ok) return;
  CHECK(running(), "%s: core not running after a successful start", name);
  CHECK(refs(t.id) == t.base + 1, "%s: %d references while running, want %d (original + one duplicate)", name,
        refs(t.id), t.base + 1);
  int dup = other_ref(t.id, t.r, t.base == 2 ? t.w : -1);
  CHECK(dup >= 0 && dup != t.r, "%s: no duplicate found while running", name);
  if (dup >= 0) {
    int flags = fcntl(dup, F_GETFD);
    CHECK(flags >= 0 && (flags & FD_CLOEXEC), "%s: the core's duplicate %d is not close-on-exec", name, dup);
  }
  ident cur;
  CHECK(ident_of(t.r, &cur) == 0 && same(cur, t.id), "%s: caller's descriptor changed while running", name);

  switch (how) {
    case STOP_TUN: {
      reply s = take(pTunStop());
      CHECK(s.ok, "%s: SingLinkTunStop: %s", name, s.text);
      break;
    }
    case STOP_ENGINE: {
      reply s = take(pStop());
      CHECK(s.ok, "%s: SingLinkStop: %s", name, s.text);
      break;
    }
    case STOP_TUN_FAILURE:
      // The interface goes away under the core (EOF on the TUN): the TUN
      // watcher stops the session and closes the duplicate.
      close(t.w);
      t.w = -1;
      if (t.base == 2) t.base = 1;
      for (int i = 0; i < 500 && running(); i++) sleep_ms(10);
      break;
  }
  CHECK(!running(), "%s: core still running after the stop", name);
  if (t.w < 0) t.w = open("/dev/null", O_WRONLY);  // keep finish_caller uniform
  finish_caller(&t, name);
  pass(name);
}

static void case_busy_engine(void) {
  const char *name = "busy engine: the refused start consumes only its own duplicate";
  tunfd a = new_tun();
  reply r = take(pTunStart(a.r, tun_config(env("SL_LINK_OK"))));
  CHECK(r.ok, "first start failed: %s", r.text);
  tunfd b = new_tun();
  reply busy = take(pTunStart(b.r, tun_config(env("SL_LINK_OK"))));
  CHECK(!busy.ok, "second start while running succeeded: %s", busy.text);
  finish_caller(&b, "busy: refused descriptor");
  CHECK(running(), "the refused start stopped the running session");
  CHECK(refs(a.id) == a.base + 1, "running session lost its duplicate");
  reply s = take(pTunStop());
  CHECK(s.ok, "stop: %s", s.text);
  finish_caller(&a, "busy: running descriptor");
  pass(name);
}

typedef struct {
  int fd;
  const char *config;
  reply r;
} start_args;

static void *start_thread(void *p) {
  start_args *a = p;
  a->r = take(pTunStart(a->fd, (char *)a->config));
  return NULL;
}

static void case_stop_during_handshake(void) {
  const char *name = "SingLinkTunStop during the handshake: the cancelled start closes its duplicate";
  tunfd t = new_tun();
  start_args args = {t.r, tun_config(env("SL_LINK_SILENT")), {0, ""}};
  pthread_t th;
  if (pthread_create(&th, NULL, start_thread, &args) != 0) abort();
  sleep_ms(500);
  CHECK(refs(t.id) == t.base + 1, "%d references during the handshake, want %d", refs(t.id), t.base + 1);
  reply s = take(pTunStop());
  CHECK(s.ok, "stop: %s", s.text);
  pthread_join(th, NULL);
  CHECK(!args.r.ok, "cancelled start reported success: %s", args.r.text);
  finish_caller(&t, name);
  pass(name);
}

// ---- local proxy authentication (App F-01) ---------------------------------

// Sends a SOCKS5 greeting offering only "no authentication"; returns the
// method byte the proxy selected (0xFF = refused), or -1.
static int socks_no_auth(const char *listen) {
  char host[64];
  const char *colon = strrchr(listen, ':');
  if (colon == NULL || (size_t)(colon - listen) >= sizeof host) return -1;
  memcpy(host, listen, (size_t)(colon - listen));
  host[colon - listen] = 0;
  struct sockaddr_in sa;
  memset(&sa, 0, sizeof sa);
  sa.sin_family = AF_INET;
  sa.sin_port = htons((unsigned short)atoi(colon + 1));
  if (inet_pton(AF_INET, host, &sa.sin_addr) != 1) return -1;
  int s = socket(AF_INET, SOCK_STREAM, 0);
  if (s < 0) return -1;
  struct timeval tv = {5, 0};
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  int method = -1;
  unsigned char hello[3] = {5, 1, 0}, ans[2];
  if (connect(s, (struct sockaddr *)&sa, sizeof sa) == 0 && write(s, hello, 3) == 3 && read(s, ans, 2) == 2 &&
      ans[0] == 5) {
    method = ans[1];
  }
  close(s);
  return method;
}

static void case_local_proxy(const char *config, int want_auth, const char *name) {
  reply r = take(pStart((char *)config));
  CHECK(r.ok, "%s: SingLinkStart: %s", name, r.text);
  if (!r.ok) return;
  char listen[64], user[128] = "", pass_[128] = "";
  CHECK(field(&r, "listen", listen, sizeof listen) == 0, "%s: no listen address in %s", name, r.text);
  field(&r, "username", user, sizeof user);
  field(&r, "password", pass_, sizeof pass_);
  if (want_auth) {
    CHECK(strlen(user) >= 16 && strlen(pass_) >= 16, "%s: missing session credentials", name);
    CHECK(socks_no_auth(listen) == 0xFF, "%s: a client without credentials was not refused", name);
  } else {
    CHECK(user[0] == 0 && pass_[0] == 0, "%s: credentials reported for an open port", name);
    CHECK(socks_no_auth(listen) == 0, "%s: system-proxy mode refused a no-auth client", name);
  }
  reply s = take(pStop());
  CHECK(s.ok, "%s: stop: %s", name, s.text);
  check_sentinels(name);
  pass(name);
}

// ---- main -------------------------------------------------------------------

int main(void) {
  signal(SIGPIPE, SIG_IGN);
  open_sentinels();
  void *lib = dlopen(env("SL_LIB"), RTLD_NOW | RTLD_LOCAL);
  if (lib == NULL) {
    fprintf(stderr, "dlopen: %s\n", dlerror());
    return 2;
  }
  pTunStart = (__typeof__(pTunStart))dlsym(lib, "SingLinkTunStart");
  pTunStop = (__typeof__(pTunStop))dlsym(lib, "SingLinkTunStop");
  pStart = (__typeof__(pStart))dlsym(lib, "SingLinkStart");
  pStop = (__typeof__(pStop))dlsym(lib, "SingLinkStop");
  pStatus = (__typeof__(pStatus))dlsym(lib, "SingLinkStatus");
  pFree = (__typeof__(pFree))dlsym(lib, "SingLinkFree");
  if (!pTunStart || !pTunStop || !pStart || !pStop || !pStatus || !pFree) {
    fprintf(stderr, "missing export\n");
    return 2;
  }

  // Warm up the Go runtime and its network poller so their own long-lived
  // descriptors exist before the first measured case.
  take(pTunStart(-1, tun_config(env("SL_LINK_CLOSED"))));
  {
    tunfd w = new_tun();
    take(pTunStart(w.r, tun_config(env("SL_LINK_CLOSED"))));
    close(w.r);
    close(w.w);
  }
  check_sentinels("warm-up");

  expect_failed_start("SingLinkTunStart: malformed config", 1, "{");
  expect_failed_start("SingLinkTunStart: invalid link", 1, tun_config("singlink://not-a-valid-link"));
  expect_failed_start("SingLinkTunStart: node unreachable", 1, tun_config(env("SL_LINK_CLOSED")));
  expect_failed_start("SingLinkTunStart: negative descriptor", 0, tun_config(env("SL_LINK_OK")));
  case_closed_descriptor_number();
  case_success(STOP_TUN, "SingLinkTunStart + SingLinkTunStop: duplicate closed on stop");
  case_success(STOP_ENGINE, "SingLinkTunStart + SingLinkStop: duplicate closed on stop");
  case_success(STOP_TUN_FAILURE, "SingLinkTunStart + TUN failure: watcher closes the duplicate");
  case_busy_engine();
  case_stop_during_handshake();

  char cfg[8192];
  snprintf(cfg, sizeof cfg, "{\"link\":\"%s\",\"listen\":\"127.0.0.1:0\"}", env("SL_LINK_OK"));
  case_local_proxy(cfg, 1, "SingLinkStart without an auth field requires credentials");
  snprintf(cfg, sizeof cfg, "{\"link\":\"%s\",\"listen\":\"127.0.0.1:0\",\"auth\":true}", env("SL_LINK_OK"));
  case_local_proxy(cfg, 1, "SingLinkStart auth:true refuses clients without credentials");
  snprintf(cfg, sizeof cfg, "{\"link\":\"%s\",\"listen\":\"127.0.0.1:0\",\"auth\":false}", env("SL_LINK_OK"));
  case_local_proxy(cfg, 0, "SingLinkStart auth:false (system proxy) stays open");

  check_sentinels("end");
  printf("%s: %d failure(s)\n", failures ? "FAIL" : "PASS", failures);
  return failures ? 1 : 0;
}
