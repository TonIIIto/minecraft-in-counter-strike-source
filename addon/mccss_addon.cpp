// ReShade add-on: puts Minecraft's picture (shared memory "Local\MCPassthroughFrame", written by the Minecraft mod) over
// Counter-Strike: Source. Every frame it reads the camera CS:S really rendered with (the engine's world-to-view matrix, via
// the VEngineClient014 interface) and re-projects Minecraft's slightly older frame to it, using Minecraft's depth, so blocks
// stay glued to the world while you turn and move.
// The SourceMod extension shares the server-side camera ("Local\MCCssPose") as a fallback and the Minecraft grid's height offset.
#include <windows.h>
#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <reshade.hpp>

using namespace reshade::api;

namespace
{
	constexpr const wchar_t *kFrameMapping = L"Local\\MCPassthroughFrame";
	constexpr const wchar_t *kPoseMapping = L"Local\\MCCssPose";
	constexpr uint32_t kMagic = 0x5450434D; // "MCPT"
	constexpr int kHeader = 4096;
	constexpr int kSlotDesc = 256;
	constexpr int kSlotDescBytes = 128;
	constexpr const char *kEffect = "MCCss.fx";
	constexpr double kUnitsPerBlock = 40.0;

	// must match extension.cpp
	struct PoseShm
	{
		volatile int64_t seq;
		double x, y, z;
		float yaw, pitch, roll, fov;
		int64_t qpc;
		int32_t valid;
		int32_t bbW, bbH;
		float yOffset;
		int32_t mcMode;
	};

	/// A camera: rotation camera-space -> Minecraft world (columns: right, up, back), position (Minecraft coordinates), tan(vfov/2).
	struct Cam
	{
		float R[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
		double pos[3] = {0, 0, 0};
		float tanV = 0.75f;
		bool valid = false;
	};

	HANDLE g_frameMap = nullptr;
	const uint8_t *g_frameView = nullptr;
	int32_t g_slots = 0;
	int64_t g_stride = 0;
	int64_t g_lastPublish = -1;
	DWORD g_nextOpen = 0;

	HANDLE g_poseMap = nullptr;
	PoseShm *g_pose = nullptr;
	DWORD g_nextPoseOpen = 0;

	struct Layer
	{
		resource tex = {0};
		resource_view srv = {0};
	};
	Layer g_world, g_depth, g_overlay;
	uint32_t g_width = 0, g_height = 0;
	bool g_hasFrame = false;
	Cam g_mcCam; // the camera Minecraft rendered the newest frame with
	float g_mcNear = 0.05f, g_mcFar = 1024.0f;
	int32_t g_mcFlags = 7;
	DWORD g_lastFrameTick = 0;
	FILE *g_log = nullptr;
	DWORD g_nextLog = 0;

	// the engine's client interface (engine.dll, "VEngineClient014")
	void *g_engine = nullptr;
	DWORD g_nextEngineTry = 0;
	using MatrixFn = const float *(*)(void *);
	constexpr int kVtWorldToScreen = 36;
	constexpr int kVtWorldToView = 37;

	void logf(const char *fmt, ...)
	{
		if (!g_log)
			g_log = fopen("mccss_addon.log", "w");
		if (!g_log)
			return;
		va_list a;
		va_start(a, fmt);
		vfprintf(g_log, fmt, a);
		va_end(a);
		fputc('\n', g_log);
		fflush(g_log);
	}

	template <typename T>
	T read(const uint8_t *p)
	{
		T v;
		std::memcpy(&v, p, sizeof(T));
		return v;
	}

	bool open_frame_mapping()
	{
		if (g_frameView)
			return true;
		if (GetTickCount() < g_nextOpen)
			return false;
		g_nextOpen = GetTickCount() + 1000;
		g_frameMap = OpenFileMappingW(FILE_MAP_READ, FALSE, kFrameMapping);
		if (!g_frameMap)
			return false;
		const auto *header = static_cast<const uint8_t *>(MapViewOfFile(g_frameMap, FILE_MAP_READ, 0, 0, kHeader));
		if (!header || read<uint32_t>(header) != kMagic)
		{
			if (header)
				UnmapViewOfFile(header);
			CloseHandle(g_frameMap);
			g_frameMap = nullptr;
			return false;
		}
		g_slots = read<int32_t>(header + 12);
		g_stride = read<int64_t>(header + 16);
		UnmapViewOfFile(header);
		g_frameView = static_cast<const uint8_t *>(MapViewOfFile(g_frameMap, FILE_MAP_READ, 0, 0, static_cast<SIZE_T>(kHeader + g_stride * g_slots)));
		if (!g_frameView)
		{
			CloseHandle(g_frameMap);
			g_frameMap = nullptr;
			return false;
		}
		reshade::log::message(reshade::log::level::info, "MCCss: connected to Minecraft's frame export");
		return true;
	}

	bool open_pose_mapping()
	{
		if (g_pose)
			return true;
		if (GetTickCount() < g_nextPoseOpen)
			return false;
		g_nextPoseOpen = GetTickCount() + 1000;
		g_poseMap = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, kPoseMapping);
		if (!g_poseMap)
			return false;
		g_pose = static_cast<PoseShm *>(MapViewOfFile(g_poseMap, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(PoseShm)));
		if (!g_pose)
		{
			CloseHandle(g_poseMap);
			g_poseMap = nullptr;
			return false;
		}
		reshade::log::message(reshade::log::level::info, "MCCss: connected to the SourceMod extension's pose");
		return true;
	}

	/// Camera-to-world rotation as Minecraft builds it: rotationYXZ(pi - yaw, -pitch, roll); the camera looks down -z, +x is right.
	void camera_rotation(float yaw, float pitch, float roll, float m[3][3])
	{
		const float d2r = 3.14159265f / 180.0f;
		const float a = 3.14159265f - yaw * d2r, b = -pitch * d2r, c = roll * d2r;
		const float ca = std::cos(a), sa = std::sin(a), cb = std::cos(b), sb = std::sin(b), cc = std::cos(c), sc = std::sin(c);
		const float ry[3][3] = {{ca, 0, sa}, {0, 1, 0}, {-sa, 0, ca}};
		const float rx[3][3] = {{1, 0, 0}, {0, cb, -sb}, {0, sb, cb}};
		const float rz[3][3] = {{cc, -sc, 0}, {sc, cc, 0}, {0, 0, 1}};
		float t[3][3] = {};
		for (int i = 0; i < 3; ++i)
			for (int j = 0; j < 3; ++j)
				for (int k = 0; k < 3; ++k)
					t[i][j] += ry[i][k] * rx[k][j];
		for (int i = 0; i < 3; ++i)
			for (int j = 0; j < 3; ++j)
			{
				m[i][j] = 0;
				for (int k = 0; k < 3; ++k)
					m[i][j] += t[i][k] * rz[k][j];
			}
	}

	/// The camera the SourceMod extension last saw on the server (a tick old, 66 Hz): the fallback.
	bool shm_camera(Cam &out)
	{
		if (!open_pose_mapping())
			return false;
		for (int i = 0; i < 8; ++i)
		{
			const int64_t s0 = g_pose->seq;
			if (s0 & 1)
				continue;
			MemoryBarrier();
			const double x = g_pose->x, y = g_pose->y, z = g_pose->z;
			const float yaw = g_pose->yaw, pitch = g_pose->pitch, roll = g_pose->roll, fov = g_pose->fov;
			const bool valid = g_pose->valid != 0;
			MemoryBarrier();
			if (g_pose->seq == s0)
			{
				if (!valid)
					return false;
				camera_rotation(yaw, pitch, roll, out.R);
				out.pos[0] = x; out.pos[1] = y; out.pos[2] = z;
				out.tanV = std::tan(fov * 3.14159265f / 180.0f * 0.5f);
				out.valid = true;
				return true;
			}
		}
		return false;
	}

	bool find_engine()
	{
		if (g_engine)
			return true;
		if (GetTickCount() < g_nextEngineTry)
			return false;
		g_nextEngineTry = GetTickCount() + 2000;
		HMODULE engine = GetModuleHandleA("engine.dll");
		if (!engine)
			return false;
		using CreateInterfaceFn = void *(*)(const char *, int *);
		const auto create = reinterpret_cast<CreateInterfaceFn>(GetProcAddress(engine, "CreateInterface"));
		if (!create)
			return false;
		g_engine = create("VEngineClient014", nullptr);
		logf("engine interface VEngineClient014 = %p", g_engine);
		return g_engine != nullptr;
	}

	/// The camera CS:S rendered the frame being presented with: the engine's world-to-view and world-to-screen matrices.
	bool engine_camera(Cam &out)
	{
		if (!find_engine())
			return false;
		const void *const *vtable = *reinterpret_cast<const void *const *const *>(g_engine);
		const float *v = reinterpret_cast<MatrixFn>(vtable[kVtWorldToView])(g_engine);
		const float *s = reinterpret_cast<MatrixFn>(vtable[kVtWorldToScreen])(g_engine);
		if (!v || !s)
			return false;
		// rows of the view matrix: right, up, back (= -forward) in Source world coordinates; the translation is column 3
		const float *row[3] = {v, v + 4, v + 8};
		for (int i = 0; i < 3; ++i)
		{
			const float len = std::sqrt(row[i][0] * row[i][0] + row[i][1] * row[i][1] + row[i][2] * row[i][2]);
			if (!(len > 0.98f && len < 1.02f))
				return false; // not a rotation: not a 3D view this frame
		}
		const double t[3] = {v[3], v[7], v[11]};
		// camera position in Source world = -R^T t
		double ps[3] = {0, 0, 0};
		for (int i = 0; i < 3; ++i)
			for (int k = 0; k < 3; ++k)
				ps[k] -= row[i][k] * t[i];
		// Source (x, y, z-up) -> Minecraft (x, y-up, z): (x, z, -y)
		for (int a = 0; a < 3; ++a)
		{
			out.R[0][a] = row[a][0];
			out.R[1][a] = row[a][2];
			out.R[2][a] = -row[a][1];
		}
		const float yOff = g_pose ? g_pose->yOffset : 0.0f;
		out.pos[0] = ps[0] / kUnitsPerBlock;
		out.pos[1] = ps[2] / kUnitsPerBlock + yOff;
		out.pos[2] = -ps[1] / kUnitsPerBlock;
		const float norm = std::sqrt(s[4] * s[4] + s[5] * s[5] + s[6] * s[6]);
		out.tanV = norm > 0.2f ? 1.0f / norm : 0.75f;
		if (!(out.tanV > 0.2f && out.tanV < 3.0f))
			out.tanV = 0.75f;
		out.valid = true;
		return true;
	}

	void destroy_layers(device *dev)
	{
		for (Layer *layer : {&g_world, &g_depth, &g_overlay})
		{
			if (layer->srv.handle != 0)
				dev->destroy_resource_view(layer->srv);
			if (layer->tex.handle != 0)
				dev->destroy_resource(layer->tex);
			*layer = Layer();
		}
		g_width = g_height = 0;
		g_hasFrame = false;
	}

	bool create_layer(device *dev, Layer &layer, uint32_t w, uint32_t h, format fmt)
	{
		if (!dev->create_resource(resource_desc(w, h, 1, 1, fmt, 1, memory_heap::gpu_only, resource_usage::shader_resource | resource_usage::copy_dest),
				nullptr, resource_usage::shader_resource, &layer.tex))
			return false;
		return dev->create_resource_view(layer.tex, resource_usage::shader_resource, resource_view_desc(fmt), &layer.srv);
	}

	void bind(effect_runtime *runtime)
	{
		runtime->update_texture_bindings("MCWORLD", g_world.srv, g_world.srv);
		runtime->update_texture_bindings("MCDEPTH", g_depth.srv, g_depth.srv);
		runtime->update_texture_bindings("MCOVERLAY", g_overlay.srv, g_overlay.srv);
	}

	void upload(effect_runtime *runtime)
	{
		const int64_t published = read<int64_t>(g_frameView + 32);
		if (published == g_lastPublish)
			return;
		const int32_t slot = read<int32_t>(g_frameView + 40);
		if (slot < 0 || slot >= g_slots)
			return;
		const uint8_t *desc = g_frameView + kSlotDesc + kSlotDescBytes * slot;
		const int64_t seq = read<int64_t>(desc);
		if (seq & 1)
			return;
		const uint32_t w = read<uint32_t>(desc + 24), h = read<uint32_t>(desc + 28);
		if (w == 0 || h == 0)
			return;
		device *dev = runtime->get_device();
		if (w != g_width || h != g_height)
		{
			destroy_layers(dev);
			if (!create_layer(dev, g_world, w, h, format::r8g8b8a8_unorm) || !create_layer(dev, g_depth, w, h, format::r32_float) ||
				!create_layer(dev, g_overlay, w, h, format::r8g8b8a8_unorm))
			{
				destroy_layers(dev);
				return;
			}
			g_width = w;
			g_height = h;
			bind(runtime);
		}
		const uint8_t *base = g_frameView + kHeader + g_stride * slot;
		const size_t layer = size_t(w) * h * 4;
		subresource_data data;
		data.row_pitch = w * 4;
		data.slice_pitch = static_cast<uint32_t>(layer);
		data.data = const_cast<uint8_t *>(base);
		dev->update_texture_region(data, g_world.tex, 0);
		data.data = const_cast<uint8_t *>(base + layer);
		dev->update_texture_region(data, g_depth.tex, 0);
		data.data = const_cast<uint8_t *>(base + 2 * layer);
		dev->update_texture_region(data, g_overlay.tex, 0);
		if (read<int64_t>(desc) != seq)
			return; // rewritten mid-copy: show the next one
		g_lastPublish = published;
		g_mcNear = read<float>(desc + 32);
		g_mcFar = read<float>(desc + 36);
		g_mcFlags = read<int32_t>(desc + 44);
		g_mcCam.tanV = std::tan(read<float>(desc + 40) * 3.14159265f / 180.0f * 0.5f);
		camera_rotation(read<float>(desc + 72), read<float>(desc + 76), read<float>(desc + 80), g_mcCam.R);
		g_mcCam.pos[0] = read<double>(desc + 48);
		g_mcCam.pos[1] = read<double>(desc + 56);
		g_mcCam.pos[2] = read<double>(desc + 64);
		g_mcCam.valid = true;
		g_hasFrame = true;
		g_lastFrameTick = GetTickCount();
	}

	void set_f3(effect_runtime *rt, const char *name, float a, float b, float c)
	{
		if (const effect_uniform_variable v = rt->find_uniform_variable(kEffect, name); v.handle != 0)
			rt->set_uniform_value_float(v, a, b, c);
	}

	void on_begin_effects(effect_runtime *runtime, command_list *, resource_view, resource_view)
	{
		uint32_t bw = 0, bh = 0;
		runtime->get_screenshot_width_and_height(&bw, &bh);
		if (open_pose_mapping() && (g_pose->bbW != int32_t(bw) || g_pose->bbH != int32_t(bh)))
		{
			g_pose->bbW = int32_t(bw);
			g_pose->bbH = int32_t(bh);
		}

		Cam cs, srv;
		const bool haveServer = shm_camera(srv);
		const bool haveEngine = engine_camera(cs);
		if (!haveEngine && haveServer)
			cs = srv;
		bool on = open_frame_mapping() && cs.valid;
		if (on)
			upload(runtime);
		on = on && g_hasFrame && GetTickCount() - g_lastFrameTick < 1500;
		if (GetTickCount() > g_nextLog)
		{
			g_nextLog = GetTickCount() + 2000;
			logf("on=%d engine=%d server=%d | engine cam pos %.2f %.2f %.2f fwd %.2f %.2f %.2f tanV %.3f | server cam pos %.2f %.2f %.2f fwd %.2f %.2f %.2f tanV %.3f",
				on, haveEngine, haveServer, cs.pos[0], cs.pos[1], cs.pos[2], -cs.R[0][2], -cs.R[1][2], -cs.R[2][2], cs.tanV,
				srv.pos[0], srv.pos[1], srv.pos[2], -srv.R[0][2], -srv.R[1][2], -srv.R[2][2], srv.tanV);
		}
		if (const effect_uniform_variable v = runtime->find_uniform_variable(kEffect, "McActive"); v.handle != 0)
			runtime->set_uniform_value_bool(v, on);
		if (!on)
			return;
		// Minecraft's hand and hotbar only while the keyboard and mouse are Minecraft's (CS:S has its own HUD otherwise)
		if (const effect_uniform_variable v = runtime->find_uniform_variable(kEffect, "ShowOverlay"); v.handle != 0)
			runtime->set_uniform_value_bool(v, g_pose && g_pose->mcMode != 0);

		// R_mc^T R_cs: CS:S camera ray -> Minecraft camera ray
		float m[3][3];
		for (int i = 0; i < 3; ++i)
			for (int j = 0; j < 3; ++j)
			{
				m[i][j] = 0;
				for (int k = 0; k < 3; ++k)
					m[i][j] += g_mcCam.R[k][i] * cs.R[k][j];
			}
		set_f3(runtime, "WarpRow0", m[0][0], m[0][1], m[0][2]);
		set_f3(runtime, "WarpRow1", m[1][0], m[1][1], m[1][2]);
		set_f3(runtime, "WarpRow2", m[2][0], m[2][1], m[2][2]);
		// CS:S's camera position in Minecraft's camera space: R_mc^T (cs pos - mc pos)
		const double d[3] = {cs.pos[0] - g_mcCam.pos[0], cs.pos[1] - g_mcCam.pos[1], cs.pos[2] - g_mcCam.pos[2]};
		float t[3];
		for (int i = 0; i < 3; ++i)
			t[i] = float(g_mcCam.R[0][i] * d[0] + g_mcCam.R[1][i] * d[1] + g_mcCam.R[2][i] * d[2]);
		set_f3(runtime, "WarpT", t[0], t[1], t[2]);
		set_f3(runtime, "WarpTan", cs.tanV, g_mcCam.tanV, float(g_width) / float(g_height));
		set_f3(runtime, "McPlanes", g_mcNear, g_mcFar, float(g_mcFlags));
	}

	void on_reloaded_effects(effect_runtime *runtime)
	{
		if (g_width != 0)
			bind(runtime);
	}

	void on_destroy_effect_runtime(effect_runtime *runtime)
	{
		destroy_layers(runtime->get_device());
	}
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID)
{
	if (reason == DLL_PROCESS_ATTACH)
	{
		if (!reshade::register_addon(module))
			return FALSE;
		reshade::register_event<reshade::addon_event::reshade_begin_effects>(on_begin_effects);
		reshade::register_event<reshade::addon_event::reshade_reloaded_effects>(on_reloaded_effects);
		reshade::register_event<reshade::addon_event::destroy_effect_runtime>(on_destroy_effect_runtime);
	}
	else if (reason == DLL_PROCESS_DETACH)
	{
		reshade::unregister_addon(module);
	}
	return TRUE;
}
