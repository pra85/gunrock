// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------


/**
 * @file
 * kernel.cuh
 *
 * @brief Load balanced Edge Map Kernel Entrypoint
 */

#pragma once
#include <gunrock/util/cta_work_distribution.cuh>
#include <gunrock/util/cta_work_progress.cuh>
#include <gunrock/util/kernel_runtime_stats.cuh>

#include <gunrock/oprtr/edge_map_partitioned/cta.cuh>

namespace gunrock {
namespace oprtr {
namespace edge_map_partitioned {

// GetRowOffsets
//
// MarkPartitionSize
//
// RelaxPartitionedEdges

template <typename KernelPolicy, typename ProblemData, typename Functor>
struct Dispatch<KernelPolicy, ProblemData, Functor, true>
{
    typedef typename KernelPolicy::VertexId         VertexId;
    typedef typename KernelPolicy::SizeT            SizeT;
    typedef typename ProblemData::DataSlice         DataSlice;

    __device__ __forceinline__ SizeT GetNeighborListLength(
                            VertexId    *&d_row_offsets,
                            VertexId    &d_vertex_id,
                            SizeT       &max_vertex,
                            SizeT       &max_edge)
    {
        SizeT first = d_vertex_id >= max_vertex ? max_edge : d_row_offsets[d_vertex_id];
        SizeT second = (d_vertex_id + 1) >= max_vertex ? max_edge : d_row_offsets[d_vertex_id+1];

        return (second > first) ? second - first : 0;
    }

    static __device__ __forceinline__ void GetEdgeCounts(
                                SizeT *&d_row_offsets,
                                VertexId *&d_queue,
                                SizeT *&d_scanned_edges,
                                SizeT &num_elements,
                                SizeT &max_vertex,
                                SizeT &max_edge)
    {
        int tid = threadIdx.x;
        int bit = blockIdx.x;

        int my_id = bid*blockDim.x + tid;
        if (my_id >= num_elements || my_idx >= max_edges)
            return;
        VertexId v_id = d_queue[my_id];
        SizeT num_edges = GetNeighborListLength(d_row_offsets, v_id, max_vertex, max_edge);
        d_scanned_edges[my_id] = num_edges;
    }

    static __device__ __forceinline__ void MarkPartitionSizes(
                                unsigned int *&needles,
                                unsigned int &split_val,
                                int &size)
    {
        int my_id = threadIdx.x + blockIdx.x*blockDim.x;

        if (my_id >= size)
            return;

        needles[my_id] = split_val * my_id;
    }

    static __device__ __forceinline__ void RelaxPartitionedEdges(
                                SizeT *&d_row_offsets,
                                VertexId *&d_column_indices,
                                SizeT *&d_scanned_edges,
                                unsigned int *&partition_starts,
                                unsigned int &num_partitions,
                                VertexId *&d_queue,
                                VertexId *&d_out,
                                DataSlice *&problem,
                                SizeT &input_queue_len,
                                SizeT &output_queue_len,
                                SizeT &partition_size,
                                SizeT &max_vertices,
                                SizeT &max_edges)
    {
        int tid = threadIdx.x;
        int bid = blockIdx.x;
        int my_id = threadIdx.x + blockIdx.x*blockDim.x;

        int my_thread_start, my_thread_end;

        my_thread_start = bid * partition_size;
        my_thread_end = (bid+1)*partition_size < output_queue_len ? (bid+1)*partition_size : output_queue_len;

        if (my_thread_start >= output_queue_len)
            return;

        int my_start_partition = partition_starts[bid];
        int my_end_partition = bid < num_partitions - 1 ? partition_starts[bid+1]+1 : input_queue_len;

        __shared__ typename KernelPolicy::SmemStorage smem_storage;
        // smem_storage.s_edges[NT]
        // smem_storage.s_vertices[NT]

        int my_work_size = my_thread_end - my_thread_start;
        int out_offset = bid * partition_size;
        int pre_offset = my_start_partition > 0 ? d_scanned_edges[my_start_partition-1] : 0;
        int e_offset = my_thread_start - pre_offset;
        int edges_processed = 0;

        while (edges_processed < my_work_size && my_start_partition < my_end_partition)
        {
            pre_offset = my_start_partition > 0 ? d_scanned_edges[my_start_partition-1] : 0;

            __syncthreads();

            smem_storage.s_edges[tid] = (my_start_partition + tid < my_end_partition ? d_scanned_edges[my_start_partition + tid] - pre_offset : max_edges);
            smem_storage.s_vertices[tid] = my_start_partition + tid < my_end_partition ? d_queue[my_start_partition+tid] : -1;

            int last = my_start_partition + KernelPolicy::THREADS >= my_end_partition ? my_end_partition - my_start_partition - 1 : KernelPolicy::THREADS - 1;

            __syncthreads();

            SizeT e_last = min(smem_storage.s_edges[last] - e_offset, my_work_size - edges_processed);
            SizeT v_index = BinarySearch<KernelPolicy::THREADS>(tid+e_offset, smem_storage.s_edges);
            VertexId v = d_queue[v_index];
            SizeT end_last = (v_index < my_end_partition ? smem_storage.s_edges[v_index] : max_edges);
            SizeT internal_offset = v_index > 0 ? smem_storage.s_edges[v_index-1] : 0;
            SizeT lookup_offset = d_row_offsets[v];

            for (int i = (tid + e_offset); i < e_last + e_offset; i+=KernelPolicy::THREADS)
            {
                if (i >= end_last)
                {
                    v_index = BinarySearch<KernelPolicy::THREADS>(i, smem_storage.s_edges);
                    v = d_queue[v_index];
                    end_last = (v_index < KernelPolicy::THREADS ? smem_storage.s_edges[v_index] : max_edges);
                    internal_offset = v_index > 0 ? smem_storage.s_edges[v_index-1] : 0;
                    lookup_offset = d_row_offsets[v];
                }

                int e = i - internal_offset;
                int lookup = lookup_offset + e;
                VertexId u = d_column_indices[lookup];
                SizeT out_index = out_offset+edges_processed+(i-e_offset);

                if (Functor::CondEdge(v, u, problem)) {
                    Functor::ApplyEdge(v, u, problem);
                    util::io::ModifiedStore<ProblemData::QUEUE_WRITE_MODIFIER>::St(
                            u,
                            d_out + out_index);
                }
                else {
                    util::io::ModifiedStore<ProblemData::QUEUE_WRITE_MODIFIER>::St(
                            -1,
                            d_out + out_index);
                }

            }
            edges_processed += e_last;
            my_start_partition += KernelPolicy::THREADS;
            e_offset = 0;
        }
    }

    static __device__ __forceinline__ void RelaxLightEdges(
                                SizeT *&d_row_offsets,
                                VertexId *&d_column_indices,
                                SizeT *&d_scanned_edges,
                                VertexId *&d_queue,
                                VertexId *&d_out,
                                DataSlice *&problem,
                                SizeT &max_vertices,
                                SizeT &max_edges)
    {
        unsigned int range = input_queue_len;
        int tid = threadIdx.x;
        int bid = blockIdx.x;
        int my_id = bid * KernelPolicy::THREADS + tid;


        __shared__ typename KernelPolicy::SmemStorage smem_storage;

        int offset = (KernelPolicy::THREADS*bid - 1) > 0 ? d_scanned_edges[KernelPolicy::THREADS*bid-1] : 0;
        int end_id = (KernelPolicy::THREADS*(bid+1)) >= range ? range - 1 : KernelPolicy::THREADS*(bid+1) - 1;

        end_id = end_id % KernelPolicy::THREADS;
        smem_storage.s_edges[tid] = (my_id < range ? d_scanned_edges[my_id] - offset : max_edges);
        smem_storage.s_vertices[tid] = (my_id < range ? d_queue[my_id] : max_vertices);

        __syncthreads();
        unsigned int size = smem_storage.s_edges[end_id];

        VertexId v, e;

        int v_index = BinarySearch<KernelPolicy::THREADS>(tid, smeme_storage.s_edges);
        v = smem_storage.s_vertices[v_index];
        int end_last = (v_index < KernelPolicy::THREADS ? smem_storage.s_edges[v_index] : max_vertices);

        for (int i = tid; i < size; i += KernelPolicy::THREADS)
        {
            if (i >= end_last)
            {
                v_index = BinarySearch<KernelPolicy::THREADS>(i, smem_storage.s_edges);
                v = smem_storage.s_vertices[v_index];
                end_last = (v_indedx < KernelPolicy::THREADS ? smem_storage.s_edges[v_index] : max_vertices);
            }

            int internal_offset = v_index > 0 ? smem_storage.s_edges[v_index-1] : 0;
            e = i - internal_offset;

            int lookup = d_row_offsets[v] + e;
            VertexId u = d_column_indices[lookup];
            
            //v:pre, u:neighbor, outoffset:offset+i
            if (Functor::CondEdge(v, u, problem)) {
                Functor::ApplyEdge(v, u, problem);
                util::io::ModifiedStore<ProblemData::QUEUE_WRITE_MODIFIER>::St(
                        u,
                        d_out + offset+i);
            }
            else {
                util::io::ModifiedStore<ProblemData::QUEUE_WRITE_MODIFIER>::St(
                        -1,
                        d_out + offset+i);
            }
        }
    }

};

/**
 * @brief Kernel entry for relax partitioned edge function
 *
 * @tparam KernelPolicy Kernel policy type for partitioned edge mapping.
 * @tparam ProblemData Problem data type for partitioned edge mapping.
 * @tparam Functor Functor type for the specific problem type.
 *
 * @param[in] d_row_offset      Device pointer of SizeT to the row offsets queue
 * @param[in] d_column_indices  Device pointer of VertexId to the column indices queue
 * @param[in] d_scanned_edges   Device pointer of scanned neighbor list queue of the current frontier
 * @param[in] partition_starts  Device pointer of partition start index computed by sorted search in moderngpu lib
 * @param[in] num_partitions    Number of partitions in the current frontier
 * @param[in] d_queue           Device pointer of VertexId to the incoming frontier queue
 * @param[out] d_out            Device pointer of VertexId to the outgoing frontier queue
 * @param[in] problem           Device pointer to the problem object
 * @param[in] input_queue_len   Length of the incoming frontier queue
 * @param[in] output_queue_len  Length of the outgoing frontier queue
 * @param[in] max_vertices      Maximum number of elements we can place into the incoming frontier
 * @param[in] max_edges         Maximum number of elements we can place into the outgoing frontier
 */
    template <typename KernelPolicy, typename ProblemData, typename Functor>
__launch_bounds__ (KernelPolicy::THREADS, KernelPolicy::CTA_OCCUPANCY)
    __global__
void RelaxPartitionedEdges(
        typename KernelPolicy::SizeT            *d_row_offsets,
        typename KernelPolicy::VertexId         *d_column_indices,
        typename KernelPolicy::SizeT            *d_scanned_edges,
        unsigned int                            *partition_starts,
        unsigned int                            num_partitions,
        typename KernelPolicy::VertexId         *d_queue,
        typename KernelPolicy::VertexId         *d_out,
        typename ProblemData::DataSlice         *problem,
        typename KernelPolicy::SizeT            input_queue_len,
        typename KernelPolicy::SizeT            output_queue_len,
        typename KernelPolicy::SizeT            partition_size,
        typename KernelPolicy::SizeT            max_vertices,
        typename KernelPolicy::SizeT            max_edges)
{
    Dispatch<KernelPolicy, ProblemData, Functor>::RelaxPartitionedEdges(
            d_row_offsets,
            d_column_indices,
            d_scanned_edges,
            partition_starts,
            num_partitions,
            d_queue,
            d_out,
            problem,
            input_queue_len,
            output_queue_len,
            partition_size,
            max_vertices,
            max_edges);
}

/**
 * @brief Kernel entry for relax light edge function
 *
 * @tparam KernelPolicy Kernel policy type for partitioned edge mapping.
 * @tparam ProblemData Problem data type for partitioned edge mapping.
 * @tparam Functor Functor type for the specific problem type.
 *
 * @param[in] d_row_offset      Device pointer of SizeT to the row offsets queue
 * @param[in] d_column_indices  Device pointer of VertexId to the column indices queue
 * @param[in] d_scanned_edges   Device pointer of scanned neighbor list queue of the current frontier
 * @param[in] d_queue           Device pointer of VertexId to the incoming frontier queue
 * @param[out] d_out            Device pointer of VertexId to the outgoing frontier queue
 * @param[in] problem           Device pointer to the problem object
 * @param[in] max_vertices      Maximum number of elements we can place into the incoming frontier
 * @param[in] max_edges         Maximum number of elements we can place into the outgoing frontier
 */
    template <typename KernelPolicy, typename ProblemData, typename Functor>
__launch_bounds__ (KernelPolicy::THREADS, KernelPolicy::CTA_OCCUPANCY)
    __global__
void RelaxLightEdges(
        typename KernelPolicy::SizeT    *d_row_offsets,
        typename KernelPolicy::VertexId *d_column_indices,
        typename KernelPolicy::SizeT    *d_scanned_edges,
        typename KernelPolicy::VertexId *d_queue,
        typename KernelPolicy::VertexId *d_out,
        typename ProblemData::DataSlice *problem,
        typename KernelPolicy::SizeT    max_vertices,
        typename KernelPolicy::SizeT    max_edges)
{
    Dispatch<KernelPolicy, ProblemData, Functor>::RelaxLightEdges(
                                d_row_offsets,
                                d_column_indices,
                                d_scanned_edges,
                                d_queue,
                                d_out,
                                problem,
                                max_vertices,
                                max_edges);
}

/**
 * @brief Kernel entry for computing neighbor list length for each vertex in the current frontier
 *
 * @tparam KernelPolicy Kernel policy type for partitioned edge mapping.
 * @tparam ProblemData Problem data type for partitioned edge mapping.
 * @tparam Functor Functor type for the specific problem type.
 *
 * @param[in] d_row_offset      Device pointer of SizeT to the row offsets queue
 * @param[in] d_queue           Device pointer of VertexId to the incoming frontier queue
 * @param[out] d_scanned_edges   Device pointer of scanned neighbor list queue of the current frontier
 * @param[in] num_elements      Length of the current frontier queue
 * @param[in] max_vertices      Maximum number of elements we can place into the incoming frontier
 * @param[in] max_edges         Maximum number of elements we can place into the outgoing frontier
 */
template <typename KernelPolicy, typename ProblemData, typename Functor>
__launch_bounds__ (KernelPolicy::THREADS, KernelPolicy::CTA_OCCUPANCY)
    __global__
void GetEdgeCounts(
                                typename KernelPolicy::SizeT *d_row_offsets,
                                typename KernelPolicy::VertexId *d_queue,
                                typename KernelPolicy::SizeT *d_scanned_edges,
                                typename KernelPolicy::SizeT num_elements,
                                typename KernelPolicy::SizeT max_vertex,
                                typename KernelPolicy::SizeT max_edge)
{
    Dispatch<KernelPolicy, ProblemData, Functor>::GetEdgeCounts(
                                    d_row_offsets,
                                    d_queue,
                                    d_scanned_edges,
                                    num_elements,
                                    max_vertex,
                                    max_edge);
}

/**
 * @brief Kernel entry for computing partition splitter indices
 *
 * @tparam KernelPolicy Kernel policy type for partitioned edge mapping.
 * @tparam ProblemData Problem data type for partitioned edge mapping.
 * @tparam Functor Functor type for the specific problem type.
 *
 * @param[out] needles              Device pointer of the partition splitter indices queue
 * @param[in] split_val             Partition size
 * @param[in] size                  Length of the partition splitter indices queue
 */
template <typename KernelPolicy, typename ProblemData, typename Functor>
__launch_bounds__ (KernelPolicy::THREADS, KernelPolicy::CTA_OCCUPANCY)
    __global__
void MarkPartitionSizes(
                                unsigned int *needles,
                                unsigned int split_val,
                                int size)
{
    Dispatch<KernelPolicy, ProblemData, Functor>::MarkPartitionSizes(
                                    needles,
                                    split_val,
                                    size);
}

} //edge_map_partitioned
} //oprtr
} //gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End: