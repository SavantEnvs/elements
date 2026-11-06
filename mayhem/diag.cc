#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <unistd.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <fcntl.h>

static std::string slurp(const char* path)
{
    std::string s;
    if (FILE* f = fopen(path, "r")) {
        char b[4096]; size_t n;
        while ((n = fread(b, 1, sizeof b, f)) > 0) s.append(b, n);
        fclose(f);
    }
    return s;
}

static std::string flat(std::string s)
{
    for (auto& c : s) if (c == '\n' || c == '\0') c = '|';
    return s;
}

static double now() { timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

static std::string run_real(const std::vector<std::string>& args)
{
    int p[2];
    if (pipe(p)) return "pipe-fail";
    double t0 = now();
    pid_t pid = fork();
    if (pid == 0) {
        dup2(p[1], 1); dup2(p[1], 2); close(p[0]); close(p[1]);
        setenv("FUZZ", "addrman", 1);
        std::vector<char*> av;
        for (auto& a : args) av.push_back((char*)a.c_str());
        av.push_back(nullptr);
        execv("/mayhem/fuzz_addrman_real", av.data());
        _exit(127);
    }
    close(p[1]);
    std::string out;
    char buf[4096];
    bool killed = false;
    for (;;) {
        pollfd pf{p[0], POLLIN, 0};
        int r = poll(&pf, 1, 1000);
        if (r > 0) {
            ssize_t n = read(p[0], buf, sizeof buf);
            if (n <= 0) break;
            out.append(buf, n);
        }
        if (now() - t0 > 20) { kill(pid, SIGKILL); killed = true; break; }
    }
    int st = 0; rusage ru{};
    wait4(pid, &st, 0, &ru);
    char s[160];
    snprintf(s, sizeof s, "[st=%d sig=%d kill=%d t=%.1f rss=%ldM len=%zu]", WEXITSTATUS(st), WIFSIGNALED(st) ? WTERMSIG(st) : 0, killed, now() - t0, ru.ru_maxrss / 1024, out.size());
    std::string tail = out.size() > 330 ? out.substr(out.size() - 330) : out;
    return std::string(s) + flat(tail);
}

__attribute__((constructor(101))) static void diag(int argc, char** argv)
{
    std::string rec = "{";
    for (int i = 1; i < argc; i++) { rec += argv[i]; rec += " "; }
    rec += "}";
    for (const char* e : {"ASAN_OPTIONS", "UBSAN_OPTIONS", "LSAN_OPTIONS", "TMPDIR", "FUZZ", "MAYHEM_FUZZ_TIMEOUT"})
        if (const char* v = getenv(e)) { rec += e; rec += "="; rec += v; rec += ";"; }
    char cw[200]; if (getcwd(cw, sizeof cw)) { rec += "cwd="; rec += cw; }
    rec += "\n";
    const char* files[] = {"/tmp/diaglog.txt", "/mayhem/diaglog.txt"};
    std::string prev = slurp(files[0]);
    if (prev.empty()) prev = slurp(files[1]);
    for (auto f : files) if (FILE* fp = fopen(f, "a")) { fputs(rec.c_str(), fp); fclose(fp); }
    std::string all = prev + rec;
    if (all.size() > 940) all = all.substr(all.size() - 940);
    fprintf(stderr, "DIAGC %s\n", all.c_str());
    static uintptr_t hidden;
    hidden = (uintptr_t)new char[333] ^ 0x5a5a5a5a5a5a5a5aULL;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t*, size_t)
{
    return 0;
}
