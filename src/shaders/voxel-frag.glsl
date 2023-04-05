#version 450
#define VOXEL_SAMPLER usampler3D(VoxelMaterial_voxel_texture, VoxelMaterial_voxel_texture_sampler)

layout(location=0) in vec2 v_Position;

const int max_steps = 512;

layout(set = 2, binding = 0) uniform utexture3D VoxelMaterial_voxel_texture;
layout(set = 2, binding = 1) uniform sampler VoxelMaterial_voxel_texture_sampler;

layout(set = 3, binding = 0) uniform CamData_eye {
    vec3 eye;
};
layout(set = 3, binding = 1) uniform CamData_right {
    vec3 right;
};
layout(set = 3, binding = 2) uniform CamData_up {
    vec3 up;
};
layout(set = 3, binding = 3) uniform CamData_forward {
    vec3 forward;
};

layout(location = 0) out vec4 o_Target;

const vec3 colors[3] = vec3[](
    vec3(0.25, 0.75, 0.5),
    vec3(0.5, 0.25, 0.125),
    vec3(0.25, 0.25, 0.25)
);

bool trace_voxels_shadow(in vec3 r0, in vec3 rd){
    ivec3 tex_size = textureSize(VOXEL_SAMPLER, 0);
    ivec3 map = ivec3(r0);
    vec3 delta_dist = abs(1.0 / rd);
    vec3 rs = sign(rd);
    vec3 side_dist = (-rs * r0 + rs * (vec3(map) + (rs * 0.5 + 0.5))) * delta_dist;

    uvec4 hit = uvec4(0u);
    int steps = 0;
    int empty_spaces = 0;
    while(steps < max_steps){
        if(empty_spaces > 0){
            empty_spaces -= 1;
        }else {
            steps++;
            hit = texelFetch(VOXEL_SAMPLER, map, 0);
            if (hit.x > 0u){
                float density = float(hit.x) / 255.0;

                uint x0 = min(texelFetchOffset(VOXEL_SAMPLER, map, 0, ivec3(-1, 0, 0)).x, 1u);
                uint x1 = min(texelFetchOffset(VOXEL_SAMPLER, map, 0, ivec3(1, 0, 0)).x, 1u);
                uint y0 = min(texelFetchOffset(VOXEL_SAMPLER, map, 0, ivec3(0, -1, 0)).x, 1u);
                uint y1 = min(texelFetchOffset(VOXEL_SAMPLER, map, 0, ivec3(0, 1, 0)).x, 1u);
                uint z0 = min(texelFetchOffset(VOXEL_SAMPLER, map, 0, ivec3(0, 0, -1)).x, 1u);
                uint z1 = min(texelFetchOffset(VOXEL_SAMPLER, map, 0, ivec3(0, 0, 1)).x, 1u);
                float mins[4] = float[](
                    0.5 - density / 2.0,
                    0.0,
                    1.0 - density,
                    0.0
                );
                float maxes[4] = float[](
                    0.5 + density / 2.0,
                    density,
                    1.0,
                    1.0
                );
                uint xi = x0 + x1 * 2u;
                uint yi = y0 + y1 * 2u;
                uint zi = z0 + z1 * 2u;
                vec3 b_min = vec3(
                    float(map.x) + mins[xi],
                    float(map.y) + mins[yi],
                    float(map.z) + mins[zi]
                );
                vec3 b_max = vec3(
                    float(map.x) + maxes[xi],
                    float(map.y) + maxes[yi],
                    float(map.z) + maxes[zi]
                );

                if(all(lessThanEqual(r0, b_max)) && all(greaterThanEqual(r0, b_min))){
                    return true;
                }

                vec3 inv_dir = 1.0 / rd;

                vec3 t0 = (b_min - r0) * inv_dir;
                vec3 t1 = (b_max - r0) * inv_dir;

                vec3 v_min = min(t0, t1);
                vec3 v_max = max(t0, t1);

                float t_min = max(v_min.x, max(v_min.y, v_min.z));
                float t_max = min(v_max.x, min(v_max.y, v_max.z));

                if(t_min <= t_max && t_min >= 0.0){
                    return true;
                }
            }else{
                empty_spaces = int(hit.y);
            }
        }

        bvec3 mask = lessThanEqual(side_dist.xyz, min(side_dist.yzx, side_dist.zxy));
        side_dist += vec3(mask) * delta_dist;
        map += ivec3(mask) * ivec3(rs);
        if(any(lessThan(map, ivec3(1))) || any(greaterThanEqual(map, tex_size - 1))){
            return false;
        }
    }

    return true;
}

bool trace_voxels(in vec3 r0, in vec3 rd, out uint material, out float depth, out vec3 normal, inout int steps){
    // Initialize texture data.
    ivec3 tex_size = textureSize(VOXEL_SAMPLER, 0);

    //Basic DDA setup
    ivec3 map = ivec3(r0);
    vec3 delta_dist = abs(1.0 / rd);
    vec3 rs = sign(rd);
    ivec3 irs = ivec3(rs); //Make this here to save performance generating later.
    vec3 side_dist = (rs * (vec3(map) - r0) + (rs * 0.5 + 0.5)) * delta_dist;
    depth = 0.0;

    uvec4 hit = uvec4(0u);
    int empty_spaces = 0;
    while(steps < max_steps){
        if(empty_spaces > 0){
            // Skip texture lookup for empty spaces.
            empty_spaces -= 1;
        }else {
            // Texture lookup step.
            steps++;
            hit = texelFetch(VOXEL_SAMPLER, map, 0);
            if (hit.x > 0u){
                // Voxel has density, set material and begin generating AABB.
                material = hit.y;

                // Create density value from hit value.
                float density = float(hit.x) / 255.0;

                // Get surrounding voxels with density clamped to 0u or 1u.
                uint x0 = min(texelFetchOffset(VOXEL_SAMPLER, map, 0, ivec3(-1, 0, 0)).x, 1u);
                uint x1 = min(texelFetchOffset(VOXEL_SAMPLER, map, 0, ivec3(1, 0, 0)).x, 1u);
                uint y0 = min(texelFetchOffset(VOXEL_SAMPLER, map, 0, ivec3(0, -1, 0)).x, 1u);
                uint y1 = min(texelFetchOffset(VOXEL_SAMPLER, map, 0, ivec3(0, 1, 0)).x, 1u);
                uint z0 = min(texelFetchOffset(VOXEL_SAMPLER, map, 0, ivec3(0, 0, -1)).x, 1u);
                uint z1 = min(texelFetchOffset(VOXEL_SAMPLER, map, 0, ivec3(0, 0, 1)).x, 1u);

                // Generate min and max offsets from the voxel position for AABB generation.
                float mins[4] = float[](
                    0.5 - density / 2.0,
                    0.0,
                    1.0 - density,
                    0.0
                );
                float maxes[4] = float[](
                    0.5 + density / 2.0,
                    density,
                    1.0,
                    1.0
                );

                // Get indices for each side such that 0u = no neighbors, 1u = neighbor 1, 2u = neighbor 2, and 3u = both.
                uint xi = x0 + x1 * 2u;
                uint yi = y0 + y1 * 2u;
                uint zi = z0 + z1 * 2u;

                // Set min and max according to the generated indices.
                vec3 b_min = vec3(
                    float(map.x) + mins[xi],
                    float(map.y) + mins[yi],
                    float(map.z) + mins[zi]
                );
                vec3 b_max = vec3(
                    float(map.x) + maxes[xi],
                    float(map.y) + maxes[yi],
                    float(map.z) + maxes[zi]
                );

                // Trace the AABB using the starting ray position.
                if(all(lessThanEqual(r0, b_max)) && all(greaterThanEqual(r0, b_min))){
                    // If the current ray is inside the box, no need to do anything else, just return.
                    depth = 0;
                    return true;
                }
                // Ray-box intersection algorithm.
                vec3 inv_dir = 1.0 / rd;

                vec3 t0 = (b_min - r0) * inv_dir;
                vec3 t1 = (b_max - r0) * inv_dir;

                vec3 v_min = min(t0, t1);
                vec3 v_max = max(t0, t1);

                float t_min = max(v_min.x, max(v_min.y, v_min.z));
                float t_max = min(v_max.x, min(v_max.y, v_max.z));

                if(t_min > t_max || t_min < 0.0){
                    // Ray missed, keep moving.
                    hit.x = 0u;
                }else {
                    // Ray hit, set the normal and depth and return true.
                    if (t1.x == t_min) normal = vec3(1.0, 0.0, 0.0);
                    if (t0.x == t_min) normal = vec3(-1.0, 0.0, 0.0);
                    if (t1.y == t_min) normal = vec3(0.0, 1.0, 0.0);
                    if (t0.y == t_min) normal = vec3(0.0, -1.0, 0.0);
                    if (t1.z == t_min) normal = vec3(0.0, 0.0, 1.0);
                    if (t0.z == t_min) normal = vec3(0.0, 0.0, -1.0);

                    depth = t_min;
                    return true;
                }
            }else{
                // We're in an empty voxel, set the empty_spaces value and keep marching on.
                empty_spaces = int(hit.y);
            }
        }

        // DDA step forward.
        bvec3 mask = lessThanEqual(side_dist.xyz, min(side_dist.yzx, side_dist.zxy));
        side_dist += vec3(mask) * delta_dist;
        map += ivec3(mask) * irs;
        if(any(lessThan(map, ivec3(1))) || any(greaterThanEqual(map, tex_size - 1))){
            // If map is at the edge of the voxel texture, return false.
            // This ensures the algorithm doesn't try to sample voxels out of bounds.
            return false;
        }
    }

    // We've marched too far.
    return false;
}

const vec3 sky_color = vec3(0.7, 0.7, 0.9);
const vec3 sun_color = vec3(1.0, 1.0, 0.9);
const vec3 sun_dir = normalize(vec3(0.5, 0.9, 0.7));
const float refl_brightness = 0.1;
const float epsilon = 0.001;

void main() {
    vec3 r0 = eye;
    vec3 rd = normalize(forward + right * v_Position.x + up * v_Position.y);
    uint material = 0u;
    float depth = 0.0;
    vec3 normal = rd;
    int steps = 0;
    if(trace_voxels(r0, rd, material, depth, normal, steps)){
        vec3 color = colors[material];
        r0 = rd * depth + r0;
        float atten = max(dot(normal, sun_dir), 0.0);
        if(atten > 0.0){
            if(trace_voxels_shadow(r0 + sun_dir * epsilon, sun_dir)){
                atten = 0.0;
            }
        }
        atten = atten * 0.9 + 0.1 * (normal.y * 0.25 + 0.75);
        vec3 lighting = sun_color * atten;
        o_Target = vec4(color * lighting, 1.0);

        rd = reflect(rd, normal);
        if (trace_voxels(r0 + rd * epsilon, rd, material, depth, normal, steps)){
            vec3 ref_color = colors[material];
            depth += epsilon;
            color *= ref_color;
            r0 = rd * depth + r0;
            atten = max(dot(normal, sun_dir), 0.0);
            if (atten > 0.0){
                if (trace_voxels_shadow(r0 + sun_dir * epsilon, sun_dir)){
                    atten = 0.0;
                }
            }
            atten = atten * 0.9 + 0.1 * (normal.y * 0.25 + 0.75);
            lighting = sun_color * atten;
            o_Target += vec4(color * lighting * refl_brightness, 0.0);
        }else{
            o_Target += vec4(color * sky_color * refl_brightness, 0.0);
        }
    }else{
        o_Target = vec4(sky_color, 1.0);
    }
    //o_Target = vec4(vec3(float(steps) / float(max_steps)), 1.0);
}
