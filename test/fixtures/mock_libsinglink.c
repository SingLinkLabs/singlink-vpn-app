// Minimal C stand-in for the Go core, used only by test/ffi_mock_test.dart to
// exercise the Dart FFI bindings against the exact libsinglink C ABI.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int running = 0;
static int frees = 0;

static char *dup(const char *s) {
  char *p = malloc(strlen(s) + 1);
  strcpy(p, s);
  return p;
}

char *SingLinkVersion(void) { return dup("{\"version\":\"1.0.0-mock\",\"protocol\":\"SingLink Beta\"}"); }

char *SingLinkParseLink(char *link) {
  if (strncmp(link, "singlink://", 11) != 0) return dup("{\"ok\":false,\"error\":\"not a singlink link\"}");
  char buf[512];
  snprintf(buf, sizeof buf,
           "{\"ok\":true,\"profile\":{\"name\":\"mock\",\"server\":\"%.200s\",\"transport\":\"tls\","
           "\"sni\":\"\",\"subject\":\"ab\",\"plan\":1,\"expiresAt\":0,\"caps\":[\"tcp\"],"
           "\"rateKbps\":0,\"maxConns\":8}}",
           link + 11);
  return dup(buf);
}

char *SingLinkStart(char *cfg) {
  if (!strstr(cfg, "\"listen\":\"127.0.0.1:1080\"")) return dup("{\"ok\":false,\"error\":\"bad cfg\"}");
  running = 1;
  return dup("{\"ok\":true}");
}

char *SingLinkStop(void) { running = 0; return dup("{\"ok\":true}"); }

char *SingLinkStatus(void) {
  char buf[256];
  snprintf(buf, sizeof buf,
           "{\"running\":%s,\"listen\":\"127.0.0.1:1080\",\"up\":10,\"down\":20,\"conns\":%d,"
           "\"since\":1700000000,\"lastError\":\"\"}",
           running ? "true" : "false", frees);
  return dup(buf);
}

char *SingLinkProbe(char *url, int timeoutMs) {
  char buf[256];
  snprintf(buf, sizeof buf, "{\"ok\":true,\"status\":204,\"latencyMs\":%d}", timeoutMs);
  return dup(buf);
}

char *SingLinkExitIP(int timeoutMs) {
  if (!running) return dup("{\"ok\":false,\"error\":\"not running\"}");
  char buf[128];
  // Echo the timeout in the last octet so the int argument is verified.
  snprintf(buf, sizeof buf, "{\"ok\":true,\"ip\":\"203.0.113.%d\"}", timeoutMs % 256);
  return dup(buf);
}

void SingLinkFree(char *p) { frees++; free(p); }
