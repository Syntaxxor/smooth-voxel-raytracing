#version 450

layout(location=0) in vec3 Vertex_Position;

layout(set = 0, binding = 0) uniform CameraViewProj {
    mat4 ViewProj;
};
layout(set = 1, binding = 0) uniform Transform {
    mat4 Model;
};

layout(location=0)out vec2 v_Position;

void main() {
    v_Position = Vertex_Position.xy;
    gl_Position = vec4(Vertex_Position, 1.0);
}
