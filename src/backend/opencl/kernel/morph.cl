#if T == double || U == double
#pragma OPENCL EXTENSION cl_khr_fp64 : enable
#endif

struct Params {
    dim_type     windLen;
    dim_type      offset;
    dim_type     dims[4];
    dim_type istrides[4];
    dim_type ostrides[4];
};

dim_type lIdx(dim_type x, dim_type y,
        dim_type stride1, dim_type stride0)
{
    return (y*stride1 + x*stride0);
}

void load2LocalMem(__local T *  shrd,
        __global const T *      in,
        dim_type lx, dim_type ly, dim_type shrdStride,
        dim_type dim0, dim_type dim1,
        dim_type gx, dim_type gy,
        dim_type inStride1, dim_type inStride0)
{
    dim_type gx_  = clamp(gx, (long)0, dim0-1);
    dim_type gy_  = clamp(gy, (long)0, dim1-1);
    shrd[ lIdx(lx, ly, shrdStride, 1) ] = in[ lIdx(gx_, gy_, inStride1, inStride0) ];
}

//kernel assumes four dimensions
//doing this to reduce one uneccesary parameter
__kernel
void morph(__global T *              out,
           __global const T *        in,
           __constant const T *      d_filt,
           __local T *               localMem,
           __constant struct Params* params,
           dim_type nonBatchBlkSize)
{
    const dim_type se_len = params->windLen;
    const dim_type halo   = se_len/2;
    const dim_type padding= 2*halo;
    const dim_type shrdLen= get_local_size(0) + padding + 1;

    // gfor batch offsets
    dim_type batchId    = get_group_id(0) / nonBatchBlkSize;
    in  += (batchId * params->istrides[2] + params->offset);
    out += (batchId * params->ostrides[2]);

    // local neighborhood indices
    const dim_type lx = get_local_id(0);
    const dim_type ly = get_local_id(1);

    // global indices
    dim_type gx = get_local_size(0) * (get_group_id(0)-batchId*nonBatchBlkSize) + lx;
    dim_type gy = get_local_size(1) * get_group_id(1) + ly;

    // offset values for pulling image to local memory
    dim_type lx2      = lx + get_local_size(0);
    dim_type ly2      = ly + get_local_size(1);
    dim_type gx2      = gx + get_local_size(0);
    dim_type gy2      = gy + get_local_size(1);

    // pull image to local memory
    load2LocalMem(localMem, in, lx, ly, shrdLen,
                  params->dims[0], params->dims[1],
                  gx-halo, gy-halo,
                  params->istrides[1], params->istrides[0]);
    if (lx<padding) {
        load2LocalMem(localMem, in, lx2, ly, shrdLen,
                      params->dims[0], params->dims[1],
                      gx2-halo, gy-halo,
                      params->istrides[1], params->istrides[0]);
    }
    if (ly<padding) {
        load2LocalMem(localMem, in, lx, ly2, shrdLen,
                      params->dims[0], params->dims[1],
                      gx-halo, gy2-halo,
                      params->istrides[1], params->istrides[0]);
    }
    if (lx<padding && ly<padding) {
        load2LocalMem(localMem, in, lx2, ly2, shrdLen,
                      params->dims[0], params->dims[1],
                      gx2-halo, gy2-halo,
                      params->istrides[1], params->istrides[0]);
    }

    dim_type i = lx + halo;
    dim_type j = ly + halo;
    barrier(CLK_LOCAL_MEM_FENCE);

    T acc = localMem[ lIdx(i, j, shrdLen, 1) ];
#pragma unroll
    for(dim_type wj=0; wj<params->windLen; ++wj) {
        dim_type joff   = wj*se_len;
        dim_type w_joff = (j+wj-halo)*shrdLen;
#pragma unroll
        for(dim_type wi=0; wi<params->windLen; ++wi) {
            T cur  = localMem[w_joff+i+wi-halo];
            if (d_filt[joff+wi]) {
                if (isDilation)
                    acc = max(acc, cur);
                else
                    acc = min(acc, cur);
            }
        }
    }

    if (gx<params->dims[0] && gy<params->dims[1]) {
        dim_type outIdx = lIdx(gx, gy, params->ostrides[1], params->ostrides[0]);
        out[outIdx] = acc;
    }
}



dim_type lIdx3D(dim_type x, dim_type y, dim_type z,
        dim_type stride2, dim_type stride1, dim_type stride0)
{
    return (z*stride2 + y*stride1 + x*stride0);
}

void load2LocVolume(__local T * shrd,
        __global const T * in,
        dim_type lx, dim_type ly, dim_type lz,
        dim_type shrdStride1, dim_type shrdStride2,
        dim_type dim0, dim_type dim1, dim_type dim2,
        dim_type gx, dim_type gy, dim_type gz,
        dim_type inStride2, dim_type inStride1, dim_type inStride0)
{
    dim_type gx_  = clamp(gx, (long)0, dim0-1);
    dim_type gy_  = clamp(gy, (long)0, dim1-1);
    dim_type gz_  = clamp(gz, (long)0, dim2-1);
    dim_type shrdIdx = lx + ly*shrdStride1 + lz*shrdStride2;
    dim_type inIdx   = gx_*inStride0 + gy_*inStride1 + gz_*inStride2;
    shrd[ shrdIdx ] = in[ inIdx ];
}

__kernel
void morph3d(__global T *              out,
             __global const T *        in,
             __constant const T *      d_filt,
             __local T *               localMem,
             __constant struct Params* params)
{
    const dim_type se_len = params->windLen;
    const dim_type halo   = se_len/2;
    const dim_type padding= 2*halo;

    const dim_type se_area   = se_len*se_len;
    const dim_type shrdLen   = get_local_size(0) + padding + 1;
    const dim_type shrdArea  = shrdLen * (get_local_size(1)+padding);

    dim_type gx, gy, gz, i, j, k;
    { // scoping out unnecessary variables
    const dim_type lx = get_local_id(0);
    const dim_type ly = get_local_id(1);
    const dim_type lz = get_local_id(2);

    gx = get_local_size(0) * get_group_id(0) + lx;
    gy = get_local_size(1) * get_group_id(1) + ly;
    gz = get_local_size(2) * get_group_id(2) + lz;

    const dim_type gx2 = gx + get_local_size(0);
    const dim_type gy2 = gy + get_local_size(1);
    const dim_type gz2 = gz + get_local_size(2);
    const dim_type lx2 = lx + get_local_size(0);
    const dim_type ly2 = ly + get_local_size(1);
    const dim_type lz2 = lz + get_local_size(2);

    // pull volume to shared memory
    load2LocVolume(localMem, in, lx, ly, lz, shrdLen, shrdArea,
                    params->dims[0], params->dims[1], params->dims[2],
                    gx-halo, gy-halo, gz-halo,
                    params->istrides[2], params->istrides[1], params->istrides[0]);
    if (lx<padding) {
        load2LocVolume(localMem, in, lx2, ly, lz, shrdLen, shrdArea,
                       params->dims[0], params->dims[1], params->dims[2],
                       gx2-halo, gy-halo, gz-halo,
                       params->istrides[2], params->istrides[1], params->istrides[0]);
    }
    if (ly<padding) {
        load2LocVolume(localMem, in, lx, ly2, lz, shrdLen, shrdArea,
                       params->dims[0], params->dims[1], params->dims[2],
                       gx-halo, gy2-halo, gz-halo,
                       params->istrides[2], params->istrides[1], params->istrides[0]);
    }
    if (lz<padding) {
        load2LocVolume(localMem, in, lx, ly, lz2, shrdLen, shrdArea,
                       params->dims[0], params->dims[1], params->dims[2],
                       gx-halo, gy-halo, gz2-halo,
                       params->istrides[2], params->istrides[1], params->istrides[0]);
    }
    if (lx<padding && ly<padding) {
        load2LocVolume(localMem, in, lx2, ly2, lz, shrdLen, shrdArea,
                       params->dims[0], params->dims[1], params->dims[2],
                       gx2-halo, gy2-halo, gz-halo,
                       params->istrides[2], params->istrides[1], params->istrides[0]);
    }
    if (ly<padding && lz<padding) {
        load2LocVolume(localMem, in, lx, ly2, lz2, shrdLen, shrdArea,
                       params->dims[0], params->dims[1], params->dims[2],
                       gx-halo, gy2-halo, gz2-halo,
                       params->istrides[2], params->istrides[1], params->istrides[0]);
    }
    if (lz<padding && lx<padding) {
        load2LocVolume(localMem, in, lx2, ly, lz2, shrdLen, shrdArea,
                       params->dims[0], params->dims[1], params->dims[2],
                       gx2-halo, gy-halo, gz2-halo,
                       params->istrides[2], params->istrides[1], params->istrides[0]);
    }
    if (lx<padding && ly<padding && lz<padding) {
        load2LocVolume(localMem, in, lx2, ly2, lz2, shrdLen, shrdArea,
                       params->dims[0], params->dims[1], params->dims[2],
                       gx2-halo, gy2-halo, gz2-halo,
                       params->istrides[2], params->istrides[1], params->istrides[0]);
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    // indices of voxel owned by current thread
    i  = lx + halo;
    j  = ly + halo;
    k  = lz + halo;
    }

    T acc = localMem[ lIdx3D(i, j, k, shrdArea, shrdLen, 1) ];
#pragma unroll
    for(dim_type wk=0; wk<se_len; ++wk) {
        dim_type koff   = wk*se_area;
        dim_type w_koff = (k+wk-halo)*shrdArea;
#pragma unroll
        for(dim_type wj=0; wj<se_len; ++wj) {
        dim_type joff   = wj*se_len;
        dim_type w_joff = (j+wj-halo)*shrdLen;
#pragma unroll
            for(dim_type wi=0; wi<se_len; ++wi) {
                T cur  = localMem[w_koff+w_joff + i+wi-halo];
                if (d_filt[koff+joff+wi]) {
                    if (isDilation)
                        acc = max(acc, cur);
                    else
                        acc = min(acc, cur);
                }
            }
        }
    }

    if (gx<params->dims[0] && gy<params->dims[1] && gz<params->dims[2]) {
        dim_type outIdx = gz * params->ostrides[2] +
                          gy * params->ostrides[1] +
                          gx * params->ostrides[0];
        out[outIdx] = acc;
    }
}