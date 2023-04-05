use bevy::{
    prelude::*,
    app::{Events, ManualEventReader},
    core::{FixedTimestep},
    input::mouse::MouseMotion,
    reflect::TypeUuid,
    render::{
        mesh::shape,
        pipeline::{PipelineDescriptor, RenderPipeline},
        render_graph::{base, AssetRenderResourcesNode, RenderGraph},
        renderer::{RenderResources},
        shader::{ShaderStage, ShaderStages},
        texture::{Extent3d, TextureDimension, TextureFormat},
    },
    math::{
        Vec3,
        vec2,
        vec3,
    },
    window::{WindowMode},
};

use noise::{NoiseFn, HybridMulti, RangeFunction, Worley};


#[derive(RenderResources, Default, TypeUuid)]
#[uuid = "6e53f088-5289-11ec-bf63-0242ac130002"]
struct VoxelMaterial{
    pub voxel_texture: Handle<Texture>,
}

#[derive(RenderResources, Default, TypeUuid)]
#[uuid = "acd10670-5414-11ec-bf63-0242ac130002"]
struct CamData {
    pub eye: Vec3,
    pub right: Vec3,
    pub up: Vec3,
    pub forward: Vec3,
}

#[derive(Default)]
struct InputState{
    mouse_motion: ManualEventReader<MouseMotion>,
    pitch: f32,
    yaw: f32,
}

struct FlyCam;  

#[derive(Copy, Clone)]
struct VoxelRenderDist{
    pub dist: u32,
}

struct VoxelPipeline(RenderPipeline);

const TICK_TIME: f64 = 1.0 / 60.0;
const TICK_TIME_32: f32 = 1.0 / 60.0;

const MOUSE_SPEED: f32 = 0.05;
const CAM_SPEED: f32 = 8.0;

const DIST_MAX: usize = 16;

const NOISE_CUTOFF: f64 = 0.65;

fn main() {
    App::build()
        .init_resource::<InputState>()
        .insert_resource(WindowDescriptor{
            width: 1920.0,
            height: 1080.0,
            mode: WindowMode::BorderlessFullscreen,
            ..Default::default()
        })
        .add_plugins(DefaultPlugins)
        .add_plugin(bevy_screen_diags::ScreenDiagsPlugin::default())
        .add_asset::<VoxelMaterial>()
        .add_asset::<CamData>()
        .insert_resource(VoxelRenderDist{dist: 256})
        .add_startup_system(setup.system())
        .add_system_set(
            SystemSet::new()
                .with_run_criteria(FixedTimestep::step(TICK_TIME))
                .with_system(update_camera.system())
        )
        .run();
}


fn calc_index(x: u32, y: u32, z: u32, size: u32) -> usize{
    (x + size * (y + size * z)) as usize
}


fn setup(
    mut commands: Commands,
    mut pipelines: ResMut<Assets<PipelineDescriptor>>,
    mut shaders: ResMut<Assets<Shader>>,
    mut meshes: ResMut<Assets<Mesh>>,
    mut textures: ResMut<Assets<Texture>>,
    render_dist: Res<VoxelRenderDist>,
    mut materials: ResMut<Assets<VoxelMaterial>>,
    mut render_graph: ResMut<RenderGraph>,
    mut cam_datas: ResMut<Assets<CamData>>,
){
    // Start by creating the pipeline.
    let pipeline_handle = pipelines.add(PipelineDescriptor::default_config(ShaderStages{
        vertex: shaders.add(Shader::from_glsl(ShaderStage::Vertex, include_str!("shaders/voxel-vert.glsl"))),
        fragment: Some(shaders.add(Shader::from_glsl(ShaderStage::Fragment, include_str!("shaders/voxel-frag.glsl")))),
    }));
    let render_pipeline = RenderPipeline::new(pipeline_handle.clone());
    commands.insert_resource(VoxelPipeline(render_pipeline.clone()));

    // Add bindings to the voxel material and camera data to the pipeline.
    render_graph.add_system_node("voxel_material", AssetRenderResourcesNode::<VoxelMaterial>::new(true));
    render_graph.add_node_edge("voxel_material", base::node::MAIN_PASS).unwrap();
    render_graph.add_system_node("cam_data", AssetRenderResourcesNode::<CamData>::new(true));
    render_graph.add_node_edge("cam_data", base::node::MAIN_PASS).unwrap();

    // Create the voxel texture.
    let voxel_texture_handle = textures.add(Texture::new_fill(
        Extent3d::new(render_dist.dist, render_dist.dist, render_dist.dist),
        TextureDimension::D3,
        &[0u8; 2],
        TextureFormat::Rg8Uint
    ));

    let mut cave_noise = Worley::new();
    cave_noise.enable_range = true;
    cave_noise.range_function = RangeFunction::Euclidean;
    cave_noise.frequency = 0.04;
    let mut height_noise = HybridMulti::new();
    height_noise.octaves = 3;
    height_noise.frequency = 0.005;
    let inv_frequency = 1.0 / cave_noise.frequency;
    let voxel_texture = textures.get_mut(voxel_texture_handle.clone()).unwrap();
    let mut data = vec![0u8; voxel_texture.data.len()];
    for x in 0..render_dist.dist{
        for z in 0..render_dist.dist{
            let height = (height_noise.get([x as f64, z as f64]) * 0.5 + 0.5) * 128.0 + 128.0;
            for y in 0..render_dist.dist{
                let i = calc_index(x, y, z, render_dist.dist) * 2;
                let x = x as f64;
                let y = y as f64;
                let z = z as f64;
                let density = height - y as f64;

                let mut caves = 0.0;

                for j in 0..3{
                    let p = 2.0_f64.powi(j);
                    let frequency = p;
                    caves += cave_noise.get([x * frequency, y * frequency, z * frequency]) / p;
                }
                caves = (caves * 0.5 + 0.5) * inv_frequency - (inv_frequency * NOISE_CUTOFF);
                let cave_mask = ((density + 4.0) / 16.0).clamp(0.0, 1.0);

                data[i] = ((density.clamp(0.0, 1.0) - (caves * cave_mask).clamp(0.0, 1.0)).clamp(0.0, 1.0) * 255.0) as u8;
                if data[i] > 0{
                    if y + 1.0 >= height.floor(){
                        data[i + 1] = 0;
                    }else if y + 5.0 >= height.floor(){
                        data[i + 1] = 1;
                    }else{
                        data[i + 1] = 2;
                    }
                }else{
                    data[i + 1] = 0;
                }
            }
        }
    }

    for _ in 0..DIST_MAX {
        for x in 0..(render_dist.dist) {
            for y in 0..(render_dist.dist) {
                for z in 0..(render_dist.dist) {
                    let i = calc_index(x, y, z, render_dist.dist) * 2;
                    let cd = data[i];
                    if cd == 0{
                        let indices = [
                            calc_index(x.min(render_dist.dist - 2) + 1, y, z, render_dist.dist) * 2,
                            calc_index(x.max(1) - 1, y, z, render_dist.dist) * 2,
                            calc_index(x, y.min(render_dist.dist - 2) + 1, z, render_dist.dist) * 2,
                            calc_index(x, y.max(1) - 1, z, render_dist.dist) * 2,
                            calc_index(x, y, z.min(render_dist.dist - 2) + 1, render_dist.dist) * 2,
                            calc_index(x, y, z.max(1) - 1, render_dist.dist) * 2,
                        ];
                        let mut m = data[i + 1] + 1;
                        for j in indices{
                            let jd = data[j];
                            if jd == 0 {
                                m = m.min(data[j + 1] + 1);
                            } else {
                                m = 0;
                            }
                        }
                        data[i + 1] = m;
                    }
                }
            }
        }
    }

    voxel_texture.data = data;

    // Create the base material referencing that texture.
    let voxel_mat = materials.add(VoxelMaterial{voxel_texture: voxel_texture_handle});

    let cam_data = cam_datas.add(CamData::default());

    // Spawn the quad to render everything.
    commands.spawn_bundle(MeshBundle{
        mesh: meshes.add(Mesh::from(shape::Quad::new(vec2(2.0, 2.0)))),
        render_pipelines: RenderPipelines::from_pipelines(vec![render_pipeline.clone()]),
        ..Default::default()
    }).insert(voxel_mat).insert(cam_data);

    // Spawn a camera. Doesn't have to be this one.
    commands.spawn_bundle(OrthographicCameraBundle::new_3d());

    // Spawn the actual camera representing the position and basis.
    commands.spawn()
        .insert(FlyCam{})
        .insert(Transform::from_translation(vec3(16.0, 255.0, 16.0)));
}


fn update_camera(
    mut windows: ResMut<Windows>,
    mut cam_datas: ResMut<Assets<CamData>>,
    mut fly_cam: Query<(&mut Transform, &FlyCam)>,
    keys: Res<Input<KeyCode>>,
    mouse_buttons: Res<Input<MouseButton>>,
    mut input_state: ResMut<InputState>,
    mouse_motion: Res<Events<MouseMotion>>,
    render_dist: Res<VoxelRenderDist>,
){
    let window = windows.get_primary_mut().unwrap();
    if mouse_buttons.just_pressed(MouseButton::Left){
        window.set_cursor_lock_mode(true);
        window.set_cursor_visibility(false);
    }
    if keys.just_pressed(KeyCode::Escape){
        window.set_cursor_lock_mode(false);
        window.set_cursor_visibility(true);
    }

    let cam_data_id = cam_datas.ids().next().unwrap();
    let mut cam_data = cam_datas.get_mut(cam_data_id).unwrap();

    let (mut transform, _) = fly_cam.single_mut().expect("Either too many or too few cameras.");

    if !window.cursor_visible() {
        for ev in input_state.mouse_motion.iter(&mouse_motion) {
            input_state.yaw += (ev.delta.x * MOUSE_SPEED).to_radians();
            input_state.pitch += (ev.delta.y * MOUSE_SPEED).to_radians();
        }
        input_state.pitch = input_state.pitch.clamp(-1.54, 1.54);
        transform.rotation = Quat::from_rotation_y(input_state.yaw) * Quat::from_rotation_x(input_state.pitch);
    }
    let forward = transform.local_z();
    let right = transform.local_x();
    let up = transform.local_y();

    if keys.pressed(KeyCode::W){
        transform.translation += forward * TICK_TIME_32 * CAM_SPEED;
    }
    if keys.pressed(KeyCode::S){
        transform.translation -= forward * TICK_TIME_32 * CAM_SPEED;
    }
    if keys.pressed(KeyCode::D){
        transform.translation += right * TICK_TIME_32 * CAM_SPEED;
    }
    if keys.pressed(KeyCode::A){
        transform.translation -= right * TICK_TIME_32 * CAM_SPEED;
    }
    transform.translation = transform.translation.min(Vec3::splat(render_dist.dist as f32));
    transform.translation = transform.translation.max(Vec3::ZERO);

    let aspect = window.width() / window.height();
    cam_data.up = vec3(up.x, up.y, up.z);
    cam_data.forward = vec3(forward.x, forward.y, forward.z);
    cam_data.right = vec3(right.x, right.y, right.z) * aspect;
    cam_data.eye = vec3(transform.translation.x, transform.translation.y, transform.translation.z);
}
