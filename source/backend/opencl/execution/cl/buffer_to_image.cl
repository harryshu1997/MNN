#define GLOBAL_SIZE_2_DIMS __private const int global_size_dim0, __private const int global_size_dim1,
#define DEAL_NON_UNIFORM_DIM2(input1, input2)                       \
    if (input1 >= global_size_dim0 || input2 >= global_size_dim1) { \
        return;                                                     \
    }
__constant sampler_t SAMPLER = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_CLAMP | CLK_FILTER_NEAREST;


__kernel void nc4hw4_buffer_to_image(GLOBAL_SIZE_2_DIMS __global const float *input_ptr, __private const int2 output_shape,
                                     __private const int channel_up_4, __write_only image2d_t output) {

    int image_width_idx  = get_global_id(0);
    int image_height_idx = get_global_id(1);

    DEAL_NON_UNIFORM_DIM2(image_width_idx, image_height_idx);

    const int batch_idx         = image_height_idx / output_shape.x;
    const int height_idx        = image_height_idx % output_shape.x;
    const int width_idx         = image_width_idx % output_shape.y;
    const int channel_block_idx = image_width_idx / output_shape.y;
    int buffer_offset =
        (((batch_idx * channel_up_4 + channel_block_idx) * output_shape.x + height_idx) * output_shape.y + width_idx) * 4;

    float4 values = vload4(0, input_ptr + buffer_offset);

    int2 coord = (int2)(image_width_idx, image_height_idx);
    write_imagef(output, coord, values);
}

__kernel void image_to_nc4hw4_buffer(GLOBAL_SIZE_2_DIMS __global float *output, /* nchw */
                                     __private const int2 output_shape,
                                     __private const int channel_up_4,
                                     __read_only image2d_t input_ptr) {
    int image_width_idx  = get_global_id(0);
    int image_height_idx = get_global_id(1);

    DEAL_NON_UNIFORM_DIM2(image_width_idx, image_height_idx);

    const int batch_idx   = image_height_idx / output_shape.x;
    const int height_idx  = image_height_idx % output_shape.x;
    const int width_idx   = image_width_idx % output_shape.y;
    int channel_block_idx = image_width_idx / output_shape.y;

    int buffer_offset =
        (((batch_idx * channel_up_4 + channel_block_idx) * output_shape.x + height_idx) * output_shape.y + width_idx) * 4;

    int2 coord        = (int2)(image_width_idx, image_height_idx);
    float4 values = read_imagef(input_ptr, SAMPLER, coord);

    vstore4(values, 0, output + buffer_offset);
}

// convert kernel : from buffer(oi ) to image(oc, ic/4)
__kernel void conv2d1x1_opt_filter_buffer_to_image(GLOBAL_SIZE_2_DIMS __global const float *input_ptr,
                                            __private const int input_channel, __private const int2 kernel_shape, __private const int ic_h_w_size,
                                            __private const int height_width_size, __write_only image2d_t output) {
    
    int ic_4_idx  = get_global_id(0); // ic/4
    int oc_idx = get_global_id(1); // oc

    DEAL_NON_UNIFORM_DIM2(ic_4_idx, oc_idx);

    const int ic_idx  = ic_4_idx * 4;

    const int buffer_offset = oc_idx * input_channel + ic_idx;
    
    float4 output_values = 0;
    if (ic_idx < input_channel) {
        const int remain_channel = input_channel - ic_idx;
        if (remain_channel >= 4) {
            output_values.x = *(input_ptr + buffer_offset);
            output_values.y = *(input_ptr + buffer_offset + 1);
            output_values.z = *(input_ptr + buffer_offset + 2);
            output_values.w = *(input_ptr + buffer_offset + 3);
        } else if (remain_channel == 3) {
            output_values.x = *(input_ptr + buffer_offset);
            output_values.y = *(input_ptr + buffer_offset + 1);
            output_values.z = *(input_ptr + buffer_offset + 2);
            output_values.w = 0;
        } else if (remain_channel == 2) {
            output_values.x = *(input_ptr + buffer_offset);
            output_values.y = *(input_ptr + buffer_offset + 1);
            output_values.z = 0;
            output_values.w = 0;
        } else if (remain_channel == 1) {
            output_values.x = *(input_ptr + buffer_offset);
            output_values.y = 0;
            output_values.z = 0;
            output_values.w = 0;
        }
    }

    write_imagef(output, (int2)(ic_4_idx, oc_idx), output_values);
}

// convert kernel : from buffer(oihw) to image(oc/4 h w , ic oc4)
__kernel void conv2d_filter_buffer_to_image(GLOBAL_SIZE_2_DIMS __global const float *input_ptr,
                                            __private const int output_channel, __private const int2 kernel_shape, __private const int ic_h_w_size,
                                            __private const int height_width_size, __write_only image2d_t output) {
    int image_width_idx  = get_global_id(0); // ic
    int image_height_idx = get_global_id(1); // oc/4 h w

    DEAL_NON_UNIFORM_DIM2(image_width_idx, image_height_idx);

    const int input_channel_4_idx  = image_width_idx;
    const int output_channel_4_idx = (image_height_idx / height_width_size) * 4;
    const int height_width_idx     = image_height_idx % height_width_size;
    const int buffer_height_idx    = height_width_idx / kernel_shape.y;
    const int buffer_width_idx     = height_width_idx % kernel_shape.y;

    const int buffer_offset = output_channel_4_idx * ic_h_w_size + input_channel_4_idx * height_width_size +
                              buffer_height_idx * kernel_shape.y + buffer_width_idx;

    float4 output_values = 0;
    if (output_channel_4_idx < output_channel) {
        const int remain_channel = output_channel - output_channel_4_idx;
        if (remain_channel >= 4) {
            int offset      = buffer_offset;
            output_values.x = *(input_ptr + offset);
            offset          = mad24(1, ic_h_w_size, offset);
            output_values.y = *(input_ptr + offset);
            offset += ic_h_w_size;
            output_values.z = *(input_ptr + offset);
            offset += ic_h_w_size;
            output_values.w = *(input_ptr + offset);
        } else if (remain_channel == 3) {
            int offset      = buffer_offset;
            output_values.x = *(input_ptr + offset);
            offset          = mad24(1, ic_h_w_size, offset);
            output_values.y = *(input_ptr + offset);
            offset += ic_h_w_size;
            output_values.z = *(input_ptr + offset);

        } else if (remain_channel == 2) {
            int offset      = buffer_offset;
            output_values.x = *(input_ptr + offset);
            offset          = mad24(1, ic_h_w_size, offset);
            output_values.y = *(input_ptr + offset);
        } else if (remain_channel == 1) {
            int offset      = buffer_offset;
            output_values.x = *(input_ptr + offset);
        }
    }

    write_imagef(output, (int2)(image_width_idx, image_height_idx), output_values);
}

// only for debug
// convert kernel : from image(oc/4 h w , ic oc4) to buffer(oihw)
__kernel void conv2d_filter_image_to_buffer(GLOBAL_SIZE_2_DIMS __global float *output_ptr,
                                            __private const int output_channel, __private const int2 kernel_shape,
                                            __private const int ic_h_w_size,
                                            __private const int height_width_size, __read_only image2d_t input_ptr) {
    int image_width_idx  = get_global_id(0);
    int image_height_idx = get_global_id(1);

    DEAL_NON_UNIFORM_DIM2(image_width_idx, image_height_idx);

    const int input_channel_4_idx  = image_width_idx;
    const int output_channel_4_idx = image_height_idx / height_width_size * 4;
    const int height_width_idx     = image_height_idx % height_width_size;
    const int buffer_height_idx    = height_width_idx / kernel_shape.y;
    const int buffer_width_idx     = height_width_idx % kernel_shape.y;

    const int buffer_offset = output_channel_4_idx * ic_h_w_size + input_channel_4_idx * height_width_size +
                              buffer_height_idx * kernel_shape.y + buffer_width_idx;

    if (output_channel_4_idx < output_channel) {
        int2 coord               = (int2)(image_width_idx, image_height_idx);
        float4 values        = read_imagef(input_ptr, SAMPLER, coord);
        const int remain_channel = (output_channel - output_channel_4_idx);

        if (remain_channel >= 4) {
            int offset         = buffer_offset;
            output_ptr[offset] = values.x;
            offset             = mad24(1, ic_h_w_size, offset);
            output_ptr[offset] = values.y;
            offset += ic_h_w_size;
            output_ptr[offset] = values.z;
            offset += ic_h_w_size;
            output_ptr[offset] = values.w;
        } else if (remain_channel == 3) {
            int offset         = buffer_offset;
            output_ptr[offset] = values.x;
            offset             = mad24(1, ic_h_w_size, offset);
            output_ptr[offset] = values.y;
            offset += ic_h_w_size;
            output_ptr[offset] = values.z;

        } else if (remain_channel == 2) {
            int offset         = buffer_offset;
            output_ptr[offset] = values.x;
            offset             = mad24(1, ic_h_w_size, offset);
            output_ptr[offset] = values.y;
        } else if (remain_channel == 1) {
            int offset         = buffer_offset;
            output_ptr[offset] = values.x;
        }
    }
}

// convert kernel from buffer(mihw) to image(ic/4, ic4 h w m)
// but now dw only support m == 1
__kernel void dw_filter_buffer_to_image(GLOBAL_SIZE_2_DIMS __global const float *input_ptr,
                                        __private const int4 kernel_shape,
                                        __private const int height_width_size, __write_only image2d_t output) {
    const int image_width_idx  = get_global_id(0);
    const int image_height_idx = get_global_id(1);

    DEAL_NON_UNIFORM_DIM2(image_width_idx, image_height_idx);

    float4 output_values = 0;
    if (kernel_shape.x == 1) {
        const int input_channel_4_idx = image_height_idx * 4;
        const int buffer_height_idx   = image_width_idx / kernel_shape.w;
        const int buffer_width_idx    = image_width_idx % kernel_shape.w;

        const int buffer_offset =
            mad24(mad24(input_channel_4_idx, kernel_shape.z, buffer_height_idx), kernel_shape.w, buffer_width_idx);

        const int remain_channel = kernel_shape.y - input_channel_4_idx;
        if (input_channel_4_idx < kernel_shape.y) {
            if (remain_channel >= 4) {
                int offset      = buffer_offset;
                output_values.x = *(input_ptr + offset);
                offset += height_width_size;
                output_values.y = *(input_ptr + offset);
                offset += height_width_size;
                output_values.z = *(input_ptr + offset);
                offset += height_width_size;
                output_values.w = *(input_ptr + offset);
            } else if (remain_channel == 3) {
                int offset      = buffer_offset;
                output_values.x = *(input_ptr + offset);
                offset += height_width_size;
                output_values.y = *(input_ptr + offset);
                offset += height_width_size;
                output_values.z = *(input_ptr + offset);

            } else if (remain_channel == 2) {
                int offset      = buffer_offset;
                output_values.x = *(input_ptr + offset);
                offset += height_width_size;
                output_values.y = *(input_ptr + offset);
            } else if (remain_channel == 1) {
                int offset      = buffer_offset;
                output_values.x = *(input_ptr + offset);
            }
        }
    }

    write_imagef(output, (int2)(image_width_idx, image_height_idx), output_values);
}

// convert data from buffer(nhwc) to image(b h, ic/4 w ic4)
__kernel void nhwc_buffer_to_image(GLOBAL_SIZE_2_DIMS __global const float *input_ptr, __private const int height,
                                   __private const int width, __private const int channels,
                                   __write_only image2d_t output) {
    int image_width_idx  = get_global_id(0);
    int image_height_idx = get_global_id(1);

    DEAL_NON_UNIFORM_DIM2(image_width_idx, image_height_idx);

    const int batch_idx     = image_height_idx / height;
    const int height_idx    = image_height_idx % height;
    const int width_idx     = image_width_idx % width;
    const int channel_4_idx = (image_width_idx / width) << 2;
    const int buffer_offset = ((batch_idx * height + height_idx) * width + width_idx) * channels + channel_4_idx;

    const int remain_channel                    = channels - channel_4_idx;
    __global const float *input_current_ptr = input_ptr + buffer_offset;
    float4 values                           = 0;
    values                                      = vload4(0, input_current_ptr);

    if (remain_channel == 3) {
        values.w = 0;
    } else if (remain_channel == 2) {
        values.z = 0;
        values.w = 0;
    } else if (remain_channel == 1) {
        values.y = 0;
        values.z = 0;
        values.w = 0;
    }
    write_imagef(output, (int2)(image_width_idx, image_height_idx), values);
}

// convert data from buffer(nchw) to image(b h, ic/4 w ic4)
__kernel void nchw_buffer_to_image(GLOBAL_SIZE_2_DIMS __global const float *input_ptr, /* nchw */
                                   __private const int height, __private const int width, __private const int channels,
                                   __write_only image2d_t output) {
    int image_width_idx  = get_global_id(0);
    int image_height_idx = get_global_id(1);

    DEAL_NON_UNIFORM_DIM2(image_width_idx, image_height_idx);

    const int batch_idx     = image_height_idx / height;
    const int height_idx    = image_height_idx % height;
    const int width_idx     = image_width_idx % width;
    const int channel_4_idx = image_width_idx / width << 2;
    const int buffer_offset = ((batch_idx * channels + channel_4_idx) * height + height_idx) * width + width_idx;

    const int remain_channel    = channels - channel_4_idx;
    const int height_width_size = height * width;
    float4 output_values    = 0;

    if (remain_channel >= 4) {
        int offset      = buffer_offset;
        output_values.x = *(input_ptr + offset);
        offset += height_width_size;
        output_values.y = *(input_ptr + offset);
        offset += height_width_size;
        output_values.z = *(input_ptr + offset);
        offset += height_width_size;
        output_values.w = *(input_ptr + offset);
    } else if (remain_channel == 3) {
        int offset      = buffer_offset;
        output_values.x = *(input_ptr + offset);
        offset += height_width_size;
        output_values.y = *(input_ptr + offset);
        offset += height_width_size;
        output_values.z = *(input_ptr + offset);
    } else if (remain_channel == 2) {
        int offset      = buffer_offset;
        output_values.x = *(input_ptr + offset);
        offset += height_width_size;
        output_values.y = *(input_ptr + offset);
    } else if (remain_channel == 1) {
        int offset      = buffer_offset;
        output_values.x = *(input_ptr + offset);
    }

    write_imagef(output, (int2)(image_width_idx, image_height_idx), output_values);
}

// only for debug
// convert data from image(b h, ic/4 w ic4) to buffer(nhwc)
__kernel void image_to_nhwc_buffer(GLOBAL_SIZE_2_DIMS __global float *output, /* nhwc */
                                   __private const int height, __private const int width, __private const int channels,
                                   __read_only image2d_t input_ptr) {
    int image_width_idx  = get_global_id(0);
    int image_height_idx = get_global_id(1);

    DEAL_NON_UNIFORM_DIM2(image_width_idx, image_height_idx);

    const int batch_idx     = image_height_idx / height;
    const int height_idx    = image_height_idx % height;
    const int width_idx     = image_width_idx % width;
    const int channel_4_idx = (image_width_idx / width) << 2;
    const int buffer_offset = ((batch_idx * height + height_idx) * width + width_idx) * channels + channel_4_idx;

    int2 coord               = (int2)(image_width_idx, image_height_idx);
    float4 values        = read_imagef(input_ptr, SAMPLER, coord);
    const int remain_channel = channels - channel_4_idx;
    if (remain_channel >= 4) {
        vstore4(values, 0, output + buffer_offset);
    } else if (remain_channel == 3) {
        int offset     = buffer_offset;
        output[offset] = values.x;
        offset++;
        output[offset] = values.y;
        offset++;
        output[offset] = values.z;
    } else if (remain_channel == 2) {
        int offset     = buffer_offset;
        output[offset] = values.x;
        offset++;
        output[offset] = values.y;
    } else if (remain_channel == 1) {
        int offset     = buffer_offset;
        output[offset] = values.x;
    }
}

// only for debug
// convert data from image(b h, ic/4 w ic4) to buffer(nhwc)
__kernel void image_to_nchw_buffer(GLOBAL_SIZE_2_DIMS __global float *output, /* nchw */
                                   __private const int height, __private const int width, __private const int channels,
                                   __read_only image2d_t input_ptr) {
    int image_width_idx  = get_global_id(0);
    int image_height_idx = get_global_id(1);

    DEAL_NON_UNIFORM_DIM2(image_width_idx, image_height_idx);

    const int batch_idx  = image_height_idx / height;
    const int height_idx = image_height_idx % height;
    const int width_idx  = image_width_idx % width;
    int channel_4_idx    = (image_width_idx / width) * 4;
    int buffer_offset    = ((batch_idx * channels + channel_4_idx) * height + height_idx) * width + width_idx;
    float4 values    = read_imagef(input_ptr, SAMPLER, (int2)(image_width_idx, image_height_idx));

    const int height_width_size = height * width;

    const int remain_channel = channels - channel_4_idx;

    if (remain_channel >= 4) {
        int offset     = buffer_offset;
        output[offset] = values.x;
        offset += height_width_size;
        output[offset] = values.y;
        offset += height_width_size;
        output[offset] = values.z;
        offset += height_width_size;
        output[offset] = values.w;
    } else if (remain_channel == 3) {
        int offset     = buffer_offset;
        output[offset] = values.x;
        offset += height_width_size;
        output[offset] = values.y;
        offset += height_width_size;
        output[offset] = values.z;
    } else if (remain_channel == 2) {
        int offset     = buffer_offset;
        output[offset] = values.x;
        offset += height_width_size;
        output[offset] = values.y;
    } else if (remain_channel == 1) {
        int offset     = buffer_offset;
        output[offset] = values.x;
    }
}

// convert arg as 4 alignment
__kernel void arg_buffer_to_image(GLOBAL_SIZE_2_DIMS __global const float *input_ptr, __private const int count,
                                  __write_only image2d_t output) {
    int image_width_idx  = get_global_id(0);
    int image_height_idx = get_global_id(1);

    DEAL_NON_UNIFORM_DIM2(image_width_idx, image_height_idx);

    const int buffer_4_offset = image_width_idx << 2;
    const int remain          = count - buffer_4_offset;

    int offset        = buffer_4_offset;
    float4 values = 0;
    if (remain >= 4) {
        values = vload4(0, input_ptr + offset);
    } else if (remain == 3) {
        values.x = *(input_ptr + offset);
        offset++;
        values.y = *(input_ptr + offset);
        offset++;
        values.z = *(input_ptr + offset);
    } else if (remain == 2) {
        values.x = *(input_ptr + offset);
        offset++;
        values.y = *(input_ptr + offset);
    } else if (remain == 1) {
        values.x = *(input_ptr + offset);
    }
    write_imagef(output, (int2)(image_width_idx, image_height_idx), values);
}

// only for debug
__kernel void arg_image_to_buffer(GLOBAL_SIZE_2_DIMS __global float *output, __private const int count,
                                  __read_only image2d_t input_ptr) {
    int image_width_idx  = get_global_id(0);
    int image_height_idx = get_global_id(1);

    DEAL_NON_UNIFORM_DIM2(image_width_idx, image_height_idx);

    const int buffer_4_offset = image_width_idx << 2;

    int2 coord        = (int2)(image_width_idx, image_height_idx);
    float4 values = read_imagef(input_ptr, SAMPLER, coord);
    const int remain  = count - buffer_4_offset;
    if (remain < 4) {
        switch (remain) {
            case 3:
                output[buffer_4_offset + 2] = values.s2;
            case 2:
                output[buffer_4_offset + 1] = values.s1;
            case 1:
                output[buffer_4_offset] = values.s0;
        }
    } else {
        vstore4(values, 0, output + buffer_4_offset);
    }

    if (remain >= 4) {
        vstore4(values, 0, output + buffer_4_offset);
    } else if (remain == 3) {
        int offset     = buffer_4_offset;
        output[offset] = values.x;
        offset++;
        output[offset] = values.y;
        offset++;
        output[offset] = values.z;
    } else if (remain == 2) {
        int offset     = buffer_4_offset;
        output[offset] = values.x;
        offset++;
        output[offset] = values.y;
    } else if (remain == 1) {
        int offset     = buffer_4_offset;
        output[offset] = values.x;
    }
}
