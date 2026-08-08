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

#ifndef NUMA_SHARED_H_INCLUDED
#define NUMA_SHARED_H_INCLUDED

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "../engine/basetypes.h"
#include "numa.h"
#include "shm.h"

namespace Stockfish {

// Utilizes shared memory.
template<typename T>
class LazyNumaReplicatedSystemWide: public NumaReplicatedBase {
   public:
    using ReplicatorFuncType = std::function<T(const T&)>;

    LazyNumaReplicatedSystemWide(NumaReplicationContext& ctx, std::unique_ptr<T>&& source) :
        NumaReplicatedBase(ctx) {
        prepare_replicate_from(std::move(source));
    }

    LazyNumaReplicatedSystemWide(const LazyNumaReplicatedSystemWide&) = delete;
    LazyNumaReplicatedSystemWide(LazyNumaReplicatedSystemWide&& other) noexcept :
        NumaReplicatedBase(std::move(other)),
        instances(std::exchange(other.instances, {})) {}

    LazyNumaReplicatedSystemWide& operator=(const LazyNumaReplicatedSystemWide&) = delete;
    LazyNumaReplicatedSystemWide& operator=(LazyNumaReplicatedSystemWide&& other) noexcept {
        NumaReplicatedBase::operator=(*this, std::move(other));
        instances = std::exchange(other.instances, {});

        return *this;
    }

    LazyNumaReplicatedSystemWide& operator=(std::unique_ptr<T>&& source) {
        prepare_replicate_from(std::move(source));

        return *this;
    }

    ~LazyNumaReplicatedSystemWide() override = default;

    const T& operator[](NumaReplicatedAccessToken token) const {
        assert(token.get_numa_index() < instances.size());
        ensure_present(token.get_numa_index());
        return *(instances[token.get_numa_index()]);
    }

    const T& operator*() const { return *(instances[0]); }

    const T* operator->() const { return &*instances[0]; }

    std::vector<std::pair<SystemWideSharedConstantAllocationStatus, std::optional<std::string>>>
    get_status_and_errors() const {
        std::vector<std::pair<SystemWideSharedConstantAllocationStatus, std::optional<std::string>>>
          status;
        status.reserve(instances.size());

        for (const auto& instance : instances)
        {
            status.emplace_back(instance.get_status(), instance.get_error_message());
        }

        return status;
    }

    template<typename FuncT>
    void modify_and_replicate(FuncT&& f) {
        auto source = std::make_unique<T>(*instances[0]);
        std::forward<FuncT>(f)(*source);
        prepare_replicate_from(std::move(source));
    }

    void on_numa_config_changed() override {
        // Use the first one as the source. It doesn't matter which one we use,
        // because they all must be identical, but the first one is guaranteed to exist.
        auto source = std::make_unique<T>(*instances[0]);
        prepare_replicate_from(std::move(source));
    }

   private:
    mutable std::vector<SystemWideSharedConstant<T>> instances;
    mutable std::mutex                               mutex;

    usize get_discriminator(NumaIndex idx) const {
        const NumaConfig& cfg     = get_numa_config();
        const NumaConfig& cfg_sys = NumaConfig::from_system(SystemNumaPolicy{}, false);
        // as a discriminator, locate the hardware/system numadomain this cpuindex belongs to
        CpuIndex    cpu     = *cfg.nodes[idx].begin();  // get a CpuIndex from NumaIndex
        NumaIndex   sys_idx = cfg_sys.is_cpu_assigned(cpu) ? cfg_sys.nodeByCpu.at(cpu) : 0;
        std::string s       = cfg_sys.to_string() + "$" + std::to_string(sys_idx);
        return static_cast<usize>(hash_string(s));
    }

    void ensure_present(NumaIndex idx) const {
        assert(idx < instances.size());

        if (instances[idx] != nullptr)
            return;

        assert(idx != 0);

        std::unique_lock<std::mutex> lock(mutex);
        // Check again for races.
        if (instances[idx] != nullptr)
            return;

        const NumaConfig& cfg = get_numa_config();
        cfg.execute_on_numa_node(idx, [this, idx]() {
            instances[idx] = SystemWideSharedConstant<T>(*instances[0], get_discriminator(idx));
        });
    }

    void prepare_replicate_from(std::unique_ptr<T>&& source) {
        instances.clear();

        const NumaConfig& cfg = get_numa_config();
        // We just need to make sure the first instance is there.
        // Note that we cannot move here as we need to reallocate the data
        // on the correct NUMA node.
        // Even in the case of a single NUMA node we have to copy since it's shared memory.
        if (cfg.requires_memory_replication())
        {
            assert(cfg.num_numa_nodes() > 0);

            cfg.execute_on_numa_node(0, [this, &source]() {
                instances.emplace_back(SystemWideSharedConstant<T>(*source, get_discriminator(0)));
            });

            // Prepare others for lazy init.
            instances.resize(cfg.num_numa_nodes());
        }
        else
        {
            assert(cfg.num_numa_nodes() == 1);
            instances.emplace_back(SystemWideSharedConstant<T>(*source, get_discriminator(0)));
        }
    }
};

}  // namespace Stockfish

#endif  // #ifndef NUMA_SHARED_H_INCLUDED
