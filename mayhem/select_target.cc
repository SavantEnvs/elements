// Upstream's single `fuzz` binary picks its target from the FUZZ env var, but Mayhem runs each target as
// its own ELF with no environment. Hard links named fuzz_<target> to that one binary carry the choice in
// argv[0]; an explicit FUZZ env var still wins, so `FUZZ=x /mayhem/fuzz` keeps working.
#include <cstdlib>
#include <cstring>
#include <sys/statvfs.h>
#include <unistd.h>

__attribute__((constructor)) static void select_fuzz_target(int argc, char** argv, char**)
{
    if (argc < 1 || argv[0] == nullptr) return;
    const char* base = std::strrchr(argv[0], '/');
    base = base ? base + 1 : argv[0];
    static const char prefix[] = "fuzz_";
    if (std::strncmp(base, prefix, sizeof(prefix) - 1) != 0) return;
    setenv("FUZZ", base + sizeof(prefix) - 1, 0);
}

// Targets built on BasicTestingSetup (addrman, *_deserialize, process_message) create their datadir under
// std::filesystem::temp_directory_path() and abort at init if it is unset, missing or read-only, and
// process_message also refuses to start with < 50 MiB free there. Point TMPDIR at the first writable
// directory with room, trying $TMPDIR, /tmp, then the working directory, so the targets start wherever
// they run. A usable $TMPDIR is left untouched.
static bool usable_dir(const char* dir, int need_room)
{
    if (dir == nullptr || dir[0] != '/' || access(dir, W_OK | X_OK) != 0) return false;
    struct statvfs st;
    if (statvfs(dir, &st) != 0 || (st.f_flag & ST_RDONLY)) return false;
    return !need_room || (unsigned long long)st.f_bavail * st.f_frsize >= 256ULL << 20;
}

__attribute__((constructor)) static void select_temp_dir()
{
    char cwd[4096];
    const char* candidates[] = {std::getenv("TMPDIR"), "/tmp", getcwd(cwd, sizeof(cwd))};
    for (int need_room = 1; need_room >= 0; --need_room) {
        for (const char* dir : candidates) {
            if (usable_dir(dir, need_room)) {
                setenv("TMPDIR", dir, 1);
                return;
            }
        }
    }
}
