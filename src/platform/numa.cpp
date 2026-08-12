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

#include "numa.h"
#include "text.h"
#include "../engine/basetypes.h"

// Kept: std::memset and assert, which this file used to reach through
// platform/memory.h. That header supplied both by accident and no longer
// includes either. IWYU asks to drop <cstring> at every tier it analyses,
// because libc++ on the lane's host provides it transitively; MinGW's libstdc++
// does not, and dropping it fails the Windows GCC jobs with "'memset' is not a
// member of 'std'" while every Linux build stays green.
#include <assert.h>
#include <cstdlib>
#include <cstring>  // IWYU pragma: keep
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>
#include <iterator>
#include <limits>
#include <string_view>

// Keep the cold half of NumaConfig here: topology discovery, the string forms,
// and thread binding. Nothing defined here runs per search node, and numa.h is
// on search.cpp's include path through search.h, so anything moved back into
// the header is parsed and offered for inlining in every engine translation
// unit for code that runs a handful of times per process.

namespace Stockfish {

NumaConfig NumaConfig::from_system([[maybe_unused]] const NumaAutoPolicy& policy,
  bool respectProcessAffinity ) {
        NumaConfig cfg = empty();

#if !((defined(__linux__) && !defined(__ANDROID__)) || defined(_WIN64))
        // Fallback for unsupported systems.
        for (CpuIndex c = 0; c < SYSTEM_THREADS_NB; ++c)
            cfg.add_cpu_to_node(NumaIndex{0}, c);
#else

    #if defined(_WIN64)

        std::optional<std::set<CpuIndex>> allowedCpus;

        if (respectProcessAffinity)
            allowedCpus = STARTUP_PROCESSOR_AFFINITY.get_combined();

        // The affinity cannot be determined in all cases on Windows,
        // but we at least guarantee that the number of allowed processors
        // is >= number of processors in the affinity mask. In case the user
        // is not satisfied they must set the processor numbers explicitly.
        auto is_cpu_allowed = [&allowedCpus](CpuIndex c) {
            return !allowedCpus.has_value() || allowedCpus->count(c) == 1;
        };

    #elif defined(__linux__) && !defined(__ANDROID__)

        std::set<CpuIndex> allowedCpus;

        if (respectProcessAffinity)
            allowedCpus = STARTUP_PROCESSOR_AFFINITY;

        auto is_cpu_allowed = [respectProcessAffinity, &allowedCpus](CpuIndex c) {
            return !respectProcessAffinity || allowedCpus.count(c) == 1;
        };

    #endif

        bool l3Success = false;
        if (!std::holds_alternative<SystemNumaPolicy>(policy))
        {
            usize l3BundleSize = 0;
            if (const auto* v = std::get_if<BundledL3Policy>(&policy))
            {
                l3BundleSize = v->bundleSize;
            }
            if (auto l3Cfg =
                  try_get_l3_aware_config(respectProcessAffinity, l3BundleSize, is_cpu_allowed))
            {
                cfg       = std::move(*l3Cfg);
                l3Success = true;
            }
        }
        if (!l3Success)
            cfg = from_system_numa(respectProcessAffinity, is_cpu_allowed);

    #if defined(_WIN64)
        // Split the NUMA nodes to be contained within a group if necessary.
        // This is needed between Windows 10 Build 20348 and Windows 11, because
        // the new NUMA allocation behaviour was introduced while there was
        // still no way to set thread affinity spanning multiple processor groups.
        // See https://learn.microsoft.com/en-us/windows/win32/procthread/numa-support
        // We also do this is if need to force old API for some reason.
        //
        // 2024-08-26: It appears that we need to actually always force this behaviour.
        // While Windows allows this to work now, such assignments have bad interaction
        // with the scheduler - in particular it still prefers scheduling on the thread's
        // "primary" node, even if it means scheduling SMT processors first.
        // See https://github.com/official-stockfish/Stockfish/issues/5551
        // See https://learn.microsoft.com/en-us/windows/win32/procthread/processor-groups
        //
        //     Each process is assigned a primary group at creation, and by default all
        //     of its threads' primary group is the same. Each thread's ideal processor
        //     is in the thread's primary group, so threads will preferentially be
        //     scheduled to processors on their primary group, but they are able to
        //     be scheduled to processors on any other group.
        //
        // used to be guarded by if (STARTUP_USE_OLD_AFFINITY_API)
        {
            NumaConfig splitCfg = empty();

            NumaIndex splitNodeIndex = 0;
            for (const auto& cpus : cfg.nodes)
            {
                if (cpus.empty())
                    continue;

                usize lastProcGroupIndex = *(cpus.begin()) / WIN_PROCESSOR_GROUP_SIZE;
                for (CpuIndex c : cpus)
                {
                    const usize procGroupIndex = c / WIN_PROCESSOR_GROUP_SIZE;
                    if (procGroupIndex != lastProcGroupIndex)
                    {
                        splitNodeIndex += 1;
                        lastProcGroupIndex = procGroupIndex;
                    }
                    splitCfg.add_cpu_to_node(splitNodeIndex, c);
                }
                splitNodeIndex += 1;
            }

            cfg = std::move(splitCfg);
        }
    #endif

#endif

        // We have to ensure no empty NUMA nodes persist.
        cfg.remove_empty_numa_nodes();

        // If the user explicitly opts out from respecting the current process affinity
        // then it may be inconsistent with the current affinity (obviously), so we
        // consider it custom.
        if (!respectProcessAffinity)
            cfg.customAffinity = true;

        return cfg;
    }

std::optional<NumaConfig> NumaConfig::from_string(const std::string& s) {
        NumaConfig cfg = empty();

        NumaIndex n = 0;
        for (auto&& nodeStr : split(s, ":"))
        {
            auto indices = indices_from_shortened_string(std::string(nodeStr));
            if (!indices.empty())
            {
                for (auto idx : indices)
                {
                    if (!cfg.add_cpu_to_node(n, CpuIndex(idx)))
                        return std::nullopt;
                }

                n += 1;
            }
        }

        if (n == 0)  // failed to parse any nodes
            return std::nullopt;

        cfg.customAffinity = true;

        return cfg;
    }

std::string NumaConfig::to_string() const {
        std::string str;

        bool isFirstNode = true;
        for (auto&& cpus : nodes)
        {
            if (!isFirstNode)
                str += ":";

            bool isFirstSet = true;
            auto rangeStart = cpus.begin();
            for (auto it = cpus.begin(); it != cpus.end(); ++it)
            {
                auto next = std::next(it);
                if (next == cpus.end() || *next != *it + 1)
                {
                    // cpus[i] is at the end of the range (may be of size 1)
                    if (!isFirstSet)
                        str += ",";

                    const CpuIndex last = *it;

                    if (it != rangeStart)
                    {
                        const CpuIndex first = *rangeStart;

                        str += std::to_string(first);
                        str += "-";
                        str += std::to_string(last);
                    }
                    else
                        str += std::to_string(last);

                    rangeStart = next;
                    isFirstSet = false;
                }
            }

            isFirstNode = false;
        }

        return str;
    }

bool NumaConfig::suggests_binding_threads(CpuIndex numThreads) const {
        // If we can reasonably determine that the threads cannot be contained
        // by the OS within the first NUMA node then we advise distributing
        // and binding threads. When the threads are not bound we can only use
        // NUMA memory replicated objects from the first node, so when the OS
        // has to schedule on other nodes we lose performance. We also suggest
        // binding if there's enough threads to distribute among nodes with minimal
        // disparity. We try to ignore small nodes, in particular the empty ones.

        // If the affinity set by the user does not match the affinity given by
        // the OS then binding is necessary to ensure the threads are running on
        // correct processors.
        if (customAffinity)
            return true;

        // We obviously cannot distribute a single thread, so a single thread
        // should never be bound.
        if (numThreads <= 1)
            return false;

        usize largestNodeSize = 0;
        for (auto&& cpus : nodes)
            if (cpus.size() > largestNodeSize)
                largestNodeSize = cpus.size();

        auto is_node_small = [largestNodeSize](const std::set<CpuIndex>& node) {
            static constexpr double SmallNodeThreshold = 0.6;
            return static_cast<double>(node.size()) / static_cast<double>(largestNodeSize)
                <= SmallNodeThreshold;
        };

        usize numNotSmallNodes = 0;
        for (auto&& cpus : nodes)
            if (!is_node_small(cpus))
                numNotSmallNodes += 1;

        return (numThreads > largestNodeSize / 2 || numThreads >= numNotSmallNodes * 4)
            && nodes.size() > 1;
    }

std::vector<NumaIndex> NumaConfig::distribute_threads_among_numa_nodes(CpuIndex numThreads) const {
        std::vector<NumaIndex> ns;

        if (nodes.size() == 1)
        {
            // Special case for when there's no NUMA nodes. This doesn't buy us
            // much, but let's keep the default path simple.
            ns.resize(numThreads, NumaIndex{0});
        }
        else
        {
            std::vector<usize> occupation(nodes.size(), 0);
            for (CpuIndex c = 0; c < numThreads; ++c)
            {
                NumaIndex bestNode{0};
                float     bestNodeFill = std::numeric_limits<float>::max();
                for (NumaIndex n = 0; n < nodes.size(); ++n)
                {
                    float fill =
                      static_cast<float>(occupation[n] + 1) / static_cast<float>(nodes[n].size());
                    // NOTE: Do we want to perhaps fill the first available node
                    //       up to 50% first before considering other nodes?
                    //       Probably not, because it would interfere with running
                    //       multiple instances. We basically shouldn't favor any
                    //       particular node.
                    if (fill < bestNodeFill)
                    {
                        bestNode     = n;
                        bestNodeFill = fill;
                    }
                }
                ns.emplace_back(bestNode);
                occupation[bestNode] += 1;
            }
        }

        return ns;
    }

NumaReplicatedAccessToken NumaConfig::bind_current_thread_to_numa_node(NumaIndex n) const {
        if (n >= nodes.size() || nodes[n].size() == 0)
            std::exit(EXIT_FAILURE);

#if defined(__linux__) && !defined(__ANDROID__)

        cpu_set_t* mask = CPU_ALLOC(highestCpuIndex + 1);
        if (mask == nullptr)
            std::exit(EXIT_FAILURE);

        const usize masksize = CPU_ALLOC_SIZE(highestCpuIndex + 1);

        CPU_ZERO_S(masksize, mask);

        for (CpuIndex c : nodes[n])
            CPU_SET_S(c, masksize, mask);

        const int status = sched_setaffinity(0, masksize, mask);

        CPU_FREE(mask);

        if (status != 0)
            std::exit(EXIT_FAILURE);

        // We yield this thread just to be sure it gets rescheduled.
        // This is defensive, allowed because this code is not performance critical.
        sched_yield();

#elif defined(_WIN64)

        // Requires Windows 11. No good way to set thread affinity spanning
        // processor groups before that.
        HMODULE k32                            = GetModuleHandle(TEXT("Kernel32.dll"));
        auto    SetThreadSelectedCpuSetMasks_f = SetThreadSelectedCpuSetMasks_t(
          (void (*)()) GetProcAddress(k32, "SetThreadSelectedCpuSetMasks"));

        // We ALWAYS set affinity with the new API if available, because
        // there's no downsides, and we forcibly keep it consistent with
        // the old API should we need to use it. I.e. we always keep this
        // as a superset of what we set with SetThreadGroupAffinity.
        if (SetThreadSelectedCpuSetMasks_f != nullptr)
        {
            // Only available on Windows 11 and Windows Server 2022 onwards
            const USHORT numProcGroups = USHORT(
              ((highestCpuIndex + 1) + WIN_PROCESSOR_GROUP_SIZE - 1) / WIN_PROCESSOR_GROUP_SIZE);
            auto groupAffinities = std::make_unique<GROUP_AFFINITY[]>(numProcGroups);
            std::memset(groupAffinities.get(), 0, sizeof(GROUP_AFFINITY) * numProcGroups);
            for (WORD i = 0; i < numProcGroups; ++i)
                groupAffinities[i].Group = i;

            for (CpuIndex c : nodes[n])
            {
                const usize procGroupIndex     = c / WIN_PROCESSOR_GROUP_SIZE;
                const usize idxWithinProcGroup = c % WIN_PROCESSOR_GROUP_SIZE;
                groupAffinities[procGroupIndex].Mask |= KAFFINITY(1) << idxWithinProcGroup;
            }

            HANDLE hThread = GetCurrentThread();

            const BOOL status =
              SetThreadSelectedCpuSetMasks_f(hThread, groupAffinities.get(), numProcGroups);
            if (status == 0)
                std::exit(EXIT_FAILURE);

            // We yield this thread just to be sure it gets rescheduled.
            // This is defensive, allowed because this code is not performance critical.
            SwitchToThread();
        }

        // Sometimes we need to force the old API, but do not use it unless necessary.
        if (SetThreadSelectedCpuSetMasks_f == nullptr || STARTUP_USE_OLD_AFFINITY_API)
        {
            // On earlier windows version (since windows 7) we cannot run a single thread
            // on multiple processor groups, so we need to restrict the group.
            // We assume the group of the first processor listed for this node.
            // Processors from outside this group will not be assigned for this thread.
            // Normally this won't be an issue because windows used to assign NUMA nodes
            // such that they cannot span processor groups. However, since Windows 10
            // Build 20348 the behaviour changed, so there's a small window of versions
            // between this and Windows 11 that might exhibit problems with not all
            // processors being utilized.
            //
            // We handle this in NumaConfig::from_system by manually splitting the
            // nodes when we detect that there is no function to set affinity spanning
            // processor nodes. This is required because otherwise our thread distribution
            // code may produce suboptimal results.
            //
            // See https://learn.microsoft.com/en-us/windows/win32/procthread/numa-support
            GROUP_AFFINITY affinity;
            std::memset(&affinity, 0, sizeof(GROUP_AFFINITY));
            // We use an ordered set to be sure to get the smallest cpu number here.
            const usize forcedProcGroupIndex = *(nodes[n].begin()) / WIN_PROCESSOR_GROUP_SIZE;
            affinity.Group                   = static_cast<WORD>(forcedProcGroupIndex);
            for (CpuIndex c : nodes[n])
            {
                const usize procGroupIndex     = c / WIN_PROCESSOR_GROUP_SIZE;
                const usize idxWithinProcGroup = c % WIN_PROCESSOR_GROUP_SIZE;
                // We skip processors that are not in the same processor group.
                // If everything was set up correctly this will never be an issue,
                // but we have to account for bad NUMA node specification.
                if (procGroupIndex != forcedProcGroupIndex)
                    continue;

                affinity.Mask |= KAFFINITY(1) << idxWithinProcGroup;
            }

            HANDLE hThread = GetCurrentThread();

            const BOOL status = SetThreadGroupAffinity(hThread, &affinity, nullptr);
            if (status == 0)
                std::exit(EXIT_FAILURE);

            // We yield this thread just to be sure it gets rescheduled. This is
            // defensive, allowed because this code is not performance critical.
            SwitchToThread();
        }

#endif

        return NumaReplicatedAccessToken(n);
    }

std::vector<usize> NumaConfig::indices_from_shortened_string(const std::string& s) {
        std::vector<usize> indices;

        if (s.empty())
            return indices;

        for (const auto& ss : split(s, ","))
        {
            if (ss.empty())
                continue;

            auto parts = split(ss, "-");
            if (parts.size() == 1)
            {
                auto c = str_to_size_t(std::string(parts[0]));
                if (c.has_value())
                    indices.emplace_back(*c);
            }
            else if (parts.size() == 2)
            {
                constexpr usize MaxIndices = 1 << 20;  // prevent oom

                auto cfirst = str_to_size_t(std::string(parts[0]));
                auto clast  = str_to_size_t(std::string(parts[1]));
                if (cfirst.has_value() && clast.has_value() && *clast - *cfirst < MaxIndices)
                {
                    for (usize c = *cfirst; c <= *clast; ++c)
                    {
                        indices.emplace_back(c);
                    }
                }
            }
        }

        return indices;
    }

NumaConfig NumaConfig::from_l3_info(std::vector<L3Domain>&& domains, usize bundleSize) {
        assert(!domains.empty());

        std::map<NumaIndex, std::vector<L3Domain>> list;
        for (auto& d : domains)
            list[d.systemNumaIndex].emplace_back(std::move(d));

        NumaConfig cfg = empty();
        NumaIndex  n   = 0;
        for (auto& [_, ds] : list)
        {
            bool changed;
            // Scan through pairs and merge them. With roughly equal L3 sizes, should give
            // a decent distribution.
            do
            {
                changed = false;
                for (usize j = 0; j + 1 < ds.size(); ++j)
                {
                    if (ds[j].cpus.size() + ds[j + 1].cpus.size() <= bundleSize)
                    {
                        changed = true;
                        ds[j].cpus.merge(ds[j + 1].cpus);
                        ds.erase(ds.begin() + j + 1);
                    }
                }
                // ds.size() has decreased if changed is true, so this loop will terminate
            } while (changed);
            for (const L3Domain& d : ds)
            {
                const NumaIndex dn = n++;
                for (CpuIndex cpu : d.cpus)
                {
                    cfg.add_cpu_to_node(dn, cpu);
                }
            }
        }
        return cfg;
    }

}  // namespace Stockfish
