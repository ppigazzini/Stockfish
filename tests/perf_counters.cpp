/*
  Stockfish, a UCI chess playing engine derived from Glaurung 2.1
  Copyright (C) 2004-2026 The Stockfish developers (see AUTHORS file)

  Stockfish is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  Stockfish is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

// Count hardware events for one child process, on any architecture tier.
//
// tests/perfbudget.sh measures retired instructions with callgrind, which is
// deterministic and blind: it simulates, so it cannot see a cache miss, a
// mispredicted branch or a stalled cycle, and it SIGILLs on the first AVX-512
// instruction it does not implement. This reads the CPU's own counters instead,
// so it covers every tier the engine actually ships and reports what the
// instruction axis is structurally unable to.
//
// Call perf_event_open directly rather than shelling out to the `perf` CLI:
// `perf` is a separate package, absent on plenty of machines whose PMU works,
// and depending on it turns a measurable host into a skipped one.
//
// PROTOCOL. Counters go to a FILE the caller names, as one `perfcounters:` line
// of key=value. Not to stderr: `bench` writes its progress there, so a shared
// stream would mix the measurement into the thing being measured. The child's
// stdout and stderr both pass through untouched. Exit status is the child's, or
// 2 if the measurement itself failed -- a rig fault must never be reported as a
// result.
//
//   tests/perf_counters -o <file> <binary> [args...]
//
// SCALING IS NOT OPTIONAL. More events than the PMU has slots are multiplexed,
// and the kernel then returns a value covering only part of the run. The read
// format carries enabled/running times for exactly that reason; ignoring them
// under-reports silently, which is the worst failure a measurement rig has. The
// `scaled=` field says whether any counter was multiplexed, so a caller can
// refuse the reading rather than quote it.

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>

#include <asm/unistd.h>
#include <linux/perf_event.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {

struct Reading {
    std::uint64_t value;
    std::uint64_t enabled;
    std::uint64_t running;
};

long perf_open(perf_event_attr* attr, pid_t pid, int cpu, int group, unsigned long flags) {
    return syscall(__NR_perf_event_open, attr, pid, cpu, group, flags);
}

// exclude_kernel is required, not tidiness: with perf_event_paranoid at 2 --
// the default on most distributions -- a request that includes kernel events is
// refused outright for an unprivileged process.
int open_counter(std::uint32_t type, std::uint64_t config, pid_t pid) {
    perf_event_attr attr{};
    attr.size           = sizeof(attr);
    attr.type           = type;
    attr.config         = config;
    attr.disabled       = 1;
    attr.enable_on_exec = 1;
    attr.exclude_kernel = 1;
    attr.exclude_hv     = 1;
    attr.inherit        = 1;
    attr.read_format    = PERF_FORMAT_TOTAL_TIME_ENABLED | PERF_FORMAT_TOTAL_TIME_RUNNING;
    return int(perf_open(&attr, pid, -1, -1, 0));
}

bool read_counter(int fd, Reading& out) {
    std::uint64_t buf[3] = {0, 0, 0};
    if (fd < 0)
        return false;
    if (read(fd, buf, sizeof(buf)) != ssize_t(sizeof(buf)))
        return false;
    out = {buf[0], buf[1], buf[2]};
    return true;
}

struct Counter {
    const char*   name;
    std::uint32_t type;
    std::uint64_t config;
    int           fd;
    Reading       reading;
    bool          ok;
};

}  // namespace

int main(int argc, char** argv) {
    if (argc < 4 || std::strcmp(argv[1], "-o") != 0)
    {
        std::fprintf(stderr, "usage: perf_counters -o <file> <binary> [args...]\n");
        return 2;
    }
    const char* outPath = argv[2];
    char** const childArgv = &argv[3];

    Counter counters[] = {
      {"instructions", PERF_TYPE_HARDWARE, PERF_COUNT_HW_INSTRUCTIONS, -1, {}, false},
      {"cycles", PERF_TYPE_HARDWARE, PERF_COUNT_HW_CPU_CYCLES, -1, {}, false},
      {"cache_misses", PERF_TYPE_HARDWARE, PERF_COUNT_HW_CACHE_MISSES, -1, {}, false},
      {"cache_refs", PERF_TYPE_HARDWARE, PERF_COUNT_HW_CACHE_REFERENCES, -1, {}, false},
      {"branch_misses", PERF_TYPE_HARDWARE, PERF_COUNT_HW_BRANCH_MISSES, -1, {}, false},
      {"branches", PERF_TYPE_HARDWARE, PERF_COUNT_HW_BRANCH_INSTRUCTIONS, -1, {}, false},
    };
    const int nCounters = int(sizeof(counters) / sizeof(counters[0]));

    // The child blocks on this pipe until the counters exist, so nothing of the
    // measured program runs uncounted. enable_on_exec then starts them exactly
    // at the execvp, which is why the fork and the shell around it are not in
    // the numbers.
    int gate[2];
    if (pipe(gate) != 0)
    {
        std::fprintf(stderr, "perfcounters: pipe failed: %s\n", std::strerror(errno));
        return 2;
    }

    const pid_t pid = fork();
    if (pid < 0)
    {
        std::fprintf(stderr, "perfcounters: fork failed: %s\n", std::strerror(errno));
        return 2;
    }

    if (pid == 0)
    {
        char one;
        close(gate[1]);
        if (read(gate[0], &one, 1) != 1)
            _exit(2);
        close(gate[0]);
        execvp(childArgv[0], childArgv);
        std::fprintf(stderr, "perfcounters: exec %s failed: %s\n", childArgv[0],
                     std::strerror(errno));
        _exit(127);
    }

    close(gate[0]);

    int opened = 0;
    for (int i = 0; i < nCounters; ++i)
    {
        counters[i].fd = open_counter(counters[i].type, counters[i].config, pid);
        if (counters[i].fd >= 0)
            ++opened;
    }

    if (opened == 0)
    {
        // Nothing counted. Release the child so it is not left blocked, then
        // report a rig fault rather than a run of zeroes.
        std::uint64_t why = std::uint64_t(errno);
        ssize_t       w   = write(gate[1], "g", 1);
        (void) w;
        close(gate[1]);
        int st = 0;
        waitpid(pid, &st, 0);
        std::fprintf(stderr,
                     "perfcounters: no counter could be opened (errno %llu: %s).\n"
                     "perfcounters: perf_event_paranoid must be 2 or lower, and a container "
                     "needs CAP_PERFMON or --privileged.\n",
                     (unsigned long long) why, std::strerror(int(why)));
        return 2;
    }

    if (write(gate[1], "g", 1) != 1)
    {
        std::fprintf(stderr, "perfcounters: could not release the child\n");
        return 2;
    }
    close(gate[1]);

    int status = 0;
    if (waitpid(pid, &status, 0) < 0)
    {
        std::fprintf(stderr, "perfcounters: waitpid failed: %s\n", std::strerror(errno));
        return 2;
    }

    bool multiplexed = false;
    char line[1024];
    int  n = std::snprintf(line, sizeof(line), "perfcounters:");

    for (int i = 0; i < nCounters; ++i)
    {
        counters[i].ok = read_counter(counters[i].fd, counters[i].reading);
        if (counters[i].fd >= 0)
            close(counters[i].fd);
        if (!counters[i].ok)
            continue;

        const Reading& r = counters[i].reading;
        if (r.running == 0)
        {
            counters[i].ok = false;
            continue;
        }

        // Scale a multiplexed counter back to the whole run, and say so.
        double value = double(r.value);
        if (r.running < r.enabled)
        {
            multiplexed = true;
            value       = value * double(r.enabled) / double(r.running);
        }

        n += std::snprintf(line + n, sizeof(line) - std::size_t(n), " %s=%.0f", counters[i].name,
                           value);
    }

    n += std::snprintf(line + n, sizeof(line) - std::size_t(n), " scaled=%d",
                       multiplexed ? 1 : 0);

    std::FILE* out = std::fopen(outPath, "w");
    if (!out)
    {
        std::fprintf(stderr, "perfcounters: cannot write %s: %s\n", outPath,
                     std::strerror(errno));
        return 2;
    }
    std::fprintf(out, "%s\n", line);
    std::fclose(out);

    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    return 2;
}
