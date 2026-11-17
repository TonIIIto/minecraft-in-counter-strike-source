/* MC Bridge - part of css-minecraft-passthrough. Built on the SourceMod extension SDK (AlliedModders).
 * Licensed under the GNU General Public License v3 (see LICENSE-GPL-3.0.txt), with the Half-Life 2 / Source engine
 * linking exception that applies to SourceMod's SDK. */
// MC Bridge: SourceMod extension that talks to the Minecraft passthrough mod (WebSocket, 127.0.0.1:25599) and
// shares the CS:S camera with the ReShade add-on (shared memory "Local\MCCssPose").
//
// Plugin natives (see mcbridge.inc):
//   MC_Camera(const float org[3], const float ang[3], float fovH)  CS:S eye position/angles -> Minecraft "cam" message + shared pose
//   MC_SetYOffset(float blocks)    vertical offset between CS:S floor and Minecraft's grid
//   MC_Send(const char[] json)     any message for the Minecraft mod
//   MC_IsConnected()
//   forward MC_OnMessage(const char[] msg)   a message from Minecraft (called on the game thread)
#include "extension.h"
#include <windows.h>
#include <winhttp.h>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

McBridge g_McBridge;
SMEXT_LINK(&g_McBridge);

namespace
{
	constexpr double kUnitsPerBlock = 40.0; // CS:S player is 72 units tall, Minecraft's 1.8 blocks
	constexpr wchar_t kPoseMapping[] = L"Local\\MCCssPose";

	struct PoseShm
	{
		volatile LONG64 seq; // odd while writing
		double x, y, z;      // Minecraft coordinates (camera)
		float yaw, pitch, roll, fov;
		LONG64 qpc;
		LONG valid;
		LONG bbW, bbH; // CS:S's picture size, written by the ReShade add-on
		float yOffset; // Minecraft y = CS:S z / 40 + yOffset
		LONG mcMode;   // 1 while the keyboard and mouse belong to Minecraft
	};

	PoseShm *g_pose = nullptr;
	HANDLE g_poseMap = nullptr;

	std::atomic<bool> g_run{false};
	std::atomic<bool> g_connected{false};
	std::thread g_thread;
	HINTERNET g_session = nullptr, g_ws = nullptr;
	std::mutex g_sendLock;
	std::mutex g_inLock;
	std::deque<std::string> g_inbox;
	std::atomic<float> g_yOffset{0.0f};
	std::atomic<long long> g_frame{0};
	IForward *g_fwdMessage = nullptr;

	void send_text(const std::string &s)
	{
		std::lock_guard<std::mutex> lock(g_sendLock);
		if (!g_connected || !g_ws)
			return;
		if (WinHttpWebSocketSend(g_ws, WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE, (PVOID)s.data(), (DWORD)s.size()) != NO_ERROR)
			g_connected = false;
	}

	void close_ws()
	{
		std::lock_guard<std::mutex> lock(g_sendLock);
		g_connected = false;
		if (g_ws)
		{
			WinHttpWebSocketClose(g_ws, WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS, nullptr, 0);
			WinHttpCloseHandle(g_ws);
			g_ws = nullptr;
		}
	}

	bool connect_ws()
	{
		HINTERNET connect = WinHttpConnect(g_session, L"127.0.0.1", 25599, 0);
		if (!connect)
			return false;
		HINTERNET req = WinHttpOpenRequest(connect, L"GET", L"/", nullptr, nullptr, nullptr, 0);
		if (!req)
		{
			WinHttpCloseHandle(connect);
			return false;
		}
		bool ok = WinHttpSetOption(req, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, nullptr, 0) &&
			WinHttpSendRequest(req, WINHTTP_NO_ADDITIONAL_HEADERS, 0, nullptr, 0, 0, 0) && WinHttpReceiveResponse(req, nullptr);
		HINTERNET ws = ok ? WinHttpWebSocketCompleteUpgrade(req, 0) : nullptr;
		WinHttpCloseHandle(req);
		if (!ws)
		{
			WinHttpCloseHandle(connect);
			return false;
		}
		{
			std::lock_guard<std::mutex> lock(g_sendLock);
			g_ws = ws;
			g_connected = true;
		}
		return true; // `connect` stays open for the life of the socket (closed with the session)
	}

	void io_thread()
	{
		std::string msg;
		char buf[16384];
		while (g_run)
		{
			if (!g_connected && !connect_ws())
			{
				for (int i = 0; i < 10 && g_run; ++i)
					Sleep(100);
				continue;
			}
			DWORD got = 0;
			WINHTTP_WEB_SOCKET_BUFFER_TYPE type;
			DWORD r = WinHttpWebSocketReceive(g_ws, buf, sizeof(buf), &got, &type);
			if (r != NO_ERROR || type == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE)
			{
				close_ws();
				msg.clear();
				continue;
			}
			msg.append(buf, got);
			if (type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE)
			{
				std::lock_guard<std::mutex> lock(g_inLock);
				if (g_inbox.size() < 2000)
					g_inbox.push_back(std::move(msg));
				msg.clear();
			}
		}
		close_ws();
	}

	// ---- Minecraft mode: the mouse wheel, number keys and mouse buttons go to Minecraft instead of CS:S's weapons ----
	// F7 toggles it (a function key: it never types a character into the console). It switches itself off on ` (console) and Esc.
	std::atomic<bool> g_mcMode{false};
	std::atomic<bool> g_drive{false};  // Minecraft flies the player (elytra) and CS:S follows
	std::atomic<bool> g_space{false};  // Space was pressed in Minecraft mode (the plugin takes it with MC_PopSpace)
	std::atomic<bool> g_flight{false}; // F10 was pressed (the plugin takes it with MC_PopFlight)
	HHOOK g_hook = nullptr;
	HWND g_gameWnd = nullptr;

	void set_mode(bool on)
	{
		g_mcMode = on;
		if (g_pose)
			g_pose->mcMode = on ? 1 : 0;
		// leaving the mode releases anything held (poll_buttons does it on its next run)
	}

	void send_key(const char *k, bool down)
	{
		char b[96];
		snprintf(b, sizeof(b), "{\"t\":\"key\",\"k\":\"%s\",\"down\":%s}", k, down ? "true" : "false");
		send_text(b);
	}

	/// Mouse buttons for Minecraft, each sent once per change (from window messages or from polling, whichever sees it first).
	void set_button(int which, bool down)
	{
		static bool state[3] = {false, false, false};
		static const char *names[3] = {"attack", "use", "pick"};
		if (state[which] == down)
			return;
		state[which] = down;
		send_key(names[which], down);
	}

	/// CS:S reads the mouse without window messages (raw input), so while Minecraft mode is on we poll the buttons.
	void poll_buttons()
	{
		const bool active = g_mcMode && g_gameWnd && GetForegroundWindow() == g_gameWnd;
		set_button(0, active && (GetAsyncKeyState(VK_LBUTTON) & 0x8000));
		set_button(1, active && (GetAsyncKeyState(VK_RBUTTON) & 0x8000));
		set_button(2, active && (GetAsyncKeyState(VK_MBUTTON) & 0x8000));
	}

	LRESULT CALLBACK GetMsgProc(int code, WPARAM wParam, LPARAM lParam)
	{
		if (code == HC_ACTION && wParam == PM_REMOVE)
		{
			MSG *m = reinterpret_cast<MSG *>(lParam);
			if (m->hwnd == g_gameWnd)
			{
				const bool mode = g_mcMode;
				switch (m->message)
				{
				case WM_KEYDOWN:
					if (m->wParam == VK_F7)
					{
						if (!(m->lParam & (1 << 30)))
							set_mode(!mode);
						m->message = WM_NULL;
					}
					else if (m->wParam == VK_F10)
					{
						if (!(m->lParam & (1 << 30)))
							g_flight = true;
						m->message = WM_NULL;
					}
					else if (mode && (m->wParam == VK_OEM_3 || m->wParam == VK_ESCAPE))
					{
						set_mode(false); // console or menu: give the keyboard back (the key itself still reaches CS:S)
					}
					else if (mode && m->wParam == VK_SPACE)
					{
						if (!(m->lParam & (1 << 30)))
							g_space = true; // not swallowed: CS:S still jumps
					}
					else if (mode && m->wParam >= '1' && m->wParam <= '9')
					{
						char b[64];
						snprintf(b, sizeof(b), "{\"t\":\"slot\",\"n\":%d}", int(m->wParam - '1'));
						send_text(b);
						m->message = WM_NULL;
					}
					else if (mode && (m->wParam == 'Q' || m->wParam == 'E' || m->wParam == 'F'))
					{
						const char *k = m->wParam == 'Q' ? "drop" : m->wParam == 'E' ? "inventory" : "swap";
						if (!(m->lParam & (1 << 30)))
						{
							send_key(k, true);
							send_key(k, false);
						}
						m->message = WM_NULL;
					}
					break;
				case WM_KEYUP:
					if (m->wParam == VK_F7 || m->wParam == VK_F10)
						m->message = WM_NULL;
					break;
				case WM_SYSKEYDOWN: case WM_SYSKEYUP:
					// F10 reaches a window as a "system key" (it opens the menu bar); it is the flight key here
					if (m->wParam == VK_F10)
					{
						if (m->message == WM_SYSKEYDOWN && !(m->lParam & (1 << 30)))
							g_flight = true;
						m->message = WM_NULL;
					}
					break;
				case WM_LBUTTONDOWN: case WM_LBUTTONUP:
					if (mode)
					{
						set_button(0, m->message == WM_LBUTTONDOWN);
						m->message = WM_NULL;
					}
					break;
				case WM_RBUTTONDOWN: case WM_RBUTTONUP:
					if (mode)
					{
						set_button(1, m->message == WM_RBUTTONDOWN);
						m->message = WM_NULL;
					}
					break;
				case WM_MBUTTONDOWN: case WM_MBUTTONUP:
					if (mode)
					{
						set_button(2, m->message == WM_MBUTTONDOWN);
						m->message = WM_NULL;
					}
					break;
				case WM_MOUSEWHEEL:
					if (mode)
					{
						const int delta = GET_WHEEL_DELTA_WPARAM(m->wParam);
						char b[64];
						snprintf(b, sizeof(b), "{\"t\":\"scroll\",\"d\":%d}", delta > 0 ? 1 : -1);
						send_text(b);
						m->message = WM_NULL;
					}
					break;
				}
			}
		}
		return CallNextHookEx(g_hook, code, wParam, lParam);
	}

	BOOL CALLBACK FindGameWindow(HWND h, LPARAM out)
	{
		DWORD pid = 0;
		GetWindowThreadProcessId(h, &pid);
		char cls[64] = {};
		GetClassNameA(h, cls, sizeof(cls));
		if (pid == GetCurrentProcessId() && strcmp(cls, "Valve001") == 0 && IsWindowVisible(h))
		{
			*reinterpret_cast<HWND *>(out) = h;
			return FALSE;
		}
		return TRUE;
	}

	/// Once a second until it works: find CS:S's window and hook its thread's message queue.
	void ensure_hook()
	{
		if (g_hook)
			return;
		static DWORD next = 0;
		if (GetTickCount() < next)
			return;
		next = GetTickCount() + 1000;
		HWND wnd = nullptr;
		EnumWindows(FindGameWindow, reinterpret_cast<LPARAM>(&wnd));
		if (!wnd)
			return;
		const DWORD thread = GetWindowThreadProcessId(wnd, nullptr);
		g_gameWnd = wnd;
		g_hook = SetWindowsHookExW(WH_GETMESSAGE, GetMsgProc, nullptr, thread);
	}

	void on_game_frame(bool)
	{
		ensure_hook();
		poll_buttons();
		// make Minecraft's window as big as CS:S's picture (again after every reconnect)
		static LONG sentW = 0, sentH = 0;
		static bool wasConnected = false;
		if (g_connected != wasConnected)
		{
			wasConnected = g_connected;
			sentW = sentH = 0;
		}
		if (g_connected && g_pose && g_pose->bbW > 0 && g_pose->bbH > 0 && (g_pose->bbW != sentW || g_pose->bbH != sentH))
		{
			sentW = g_pose->bbW;
			sentH = g_pose->bbH;
			char view[96];
			snprintf(view, sizeof(view), "{\"t\":\"view\",\"w\":%ld,\"h\":%ld}", sentW, sentH);
			send_text(view);
		}

		if (!g_fwdMessage)
			return;
		for (int n = 0; n < 200; ++n)
		{
			std::string m;
			{
				std::lock_guard<std::mutex> lock(g_inLock);
				if (g_inbox.empty())
					break;
				m = std::move(g_inbox.front());
				g_inbox.pop_front();
			}
			if (g_fwdMessage->GetFunctionCount() == 0)
				continue;
			g_fwdMessage->PushString(m.c_str());
			g_fwdMessage->Execute(nullptr);
		}
	}

	cell_t Native_Camera(IPluginContext *ctx, const cell_t *params)
	{
		cell_t *org, *ang;
		ctx->LocalToPhysAddr(params[1], &org);
		ctx->LocalToPhysAddr(params[2], &ang);
		const double fovH = sp_ctof(params[3]);
		const double x = sp_ctof(org[0]), y = sp_ctof(org[1]), z = sp_ctof(org[2]);
		const double pitch = sp_ctof(ang[0]), yaw = sp_ctof(ang[1]), roll = sp_ctof(ang[2]);
		// CS:S (x, y, z-up, yaw CCW from +x, pitch down positive) -> Minecraft (x, y-up, z, yaw 0 = +z, pitch down positive)
		const double mx = x / kUnitsPerBlock, my = z / kUnitsPerBlock + g_yOffset, mz = -y / kUnitsPerBlock;
		double myaw = -90.0 - yaw;
		myaw = std::fmod(myaw, 360.0);
		if (myaw > 180.0) myaw -= 360.0;
		if (myaw < -180.0) myaw += 360.0;
		// CS:S's fov is horizontal for a 4:3 screen; Minecraft wants the vertical one
		const double vfov = 2.0 * std::atan(std::tan(fovH * 0.0174532925 * 0.5) * 0.75) * 57.29577951;
		const long long frame = ++g_frame;
		char json[640];
		char drive[96] = "";
		if (g_drive)
			snprintf(drive, sizeof(drive), ",\"drive\":true,\"look\":[%.3f,%.3f]", myaw, pitch); // elytra: where the mouse looks steers
		// "pl": Steve's feet (Minecraft's eye height is 1.62 blocks), so he stands where the CS:S player does
		snprintf(json, sizeof(json),
			"{\"t\":\"cam\",\"f\":%lld,\"p\":[%.4f,%.4f,%.4f],\"r\":[%.3f,%.3f,%.3f],\"fov\":%.3f,\"fp\":true,\"pl\":[%.4f,%.4f,%.4f],\"h\":%.3f%s}",
			frame, mx, my, mz, myaw, pitch, -roll, vfov, mx, my - 1.62, mz, myaw, drive);
		send_text(json);
		if (g_pose)
		{
			LARGE_INTEGER t;
			QueryPerformanceCounter(&t);
			const LONG64 s = g_pose->seq;
			g_pose->seq = s | 1;
			MemoryBarrier();
			g_pose->x = mx; g_pose->y = my; g_pose->z = mz;
			g_pose->yaw = (float)myaw; g_pose->pitch = (float)pitch; g_pose->roll = (float)-roll; g_pose->fov = (float)vfov;
			g_pose->qpc = t.QuadPart;
			g_pose->yOffset = g_yOffset;
			g_pose->valid = 1;
			MemoryBarrier();
			g_pose->seq = (s | 1) + 1;
		}
		return 0;
	}

	cell_t Native_SetYOffset(IPluginContext *, const cell_t *params)
	{
		g_yOffset = sp_ctof(params[1]);
		return 0;
	}

	cell_t Native_Send(IPluginContext *ctx, const cell_t *params)
	{
		char *s;
		ctx->LocalToString(params[1], &s);
		send_text(s);
		return 0;
	}

	cell_t Native_IsConnected(IPluginContext *, const cell_t *)
	{
		return g_connected ? 1 : 0;
	}

	cell_t Native_SetMode(IPluginContext *, const cell_t *params)
	{
		set_mode(params[1] != 0);
		return 0;
	}

	cell_t Native_GetMode(IPluginContext *, const cell_t *)
	{
		return g_mcMode ? 1 : 0;
	}

	cell_t Native_SetDrive(IPluginContext *, const cell_t *params)
	{
		g_drive = params[1] != 0;
		return 0;
	}

	cell_t Native_PopSpace(IPluginContext *, const cell_t *)
	{
		return g_space.exchange(false) ? 1 : 0;
	}

	cell_t Native_PopFlight(IPluginContext *, const cell_t *)
	{
		return g_flight.exchange(false) ? 1 : 0;
	}

	const sp_nativeinfo_t g_Natives[] = {
		{"MC_PopFlight", Native_PopFlight},
		{"MC_SetDrive", Native_SetDrive},
		{"MC_PopSpace", Native_PopSpace},
		{"MC_SetMode", Native_SetMode},
		{"MC_GetMode", Native_GetMode},
		{"MC_Camera", Native_Camera},
		{"MC_SetYOffset", Native_SetYOffset},
		{"MC_Send", Native_Send},
		{"MC_IsConnected", Native_IsConnected},
		{nullptr, nullptr},
	};
}

bool McBridge::SDK_OnLoad(char *error, size_t maxlen, bool late)
{
	g_poseMap = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, sizeof(PoseShm), kPoseMapping);
	if (g_poseMap)
	{
		g_pose = (PoseShm *)MapViewOfFile(g_poseMap, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(PoseShm));
		if (g_pose)
			memset((void *)g_pose, 0, sizeof(PoseShm));
	}
	g_session = WinHttpOpen(L"mcbridge/0.1", WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
	if (!g_session)
	{
		snprintf(error, maxlen, "WinHttpOpen failed (%lu)", GetLastError());
		return false;
	}
	g_run = true;
	g_thread = std::thread(io_thread);
	smutils->AddGameFrameHook(on_game_frame);
	return true;
}

void McBridge::SDK_OnAllLoaded()
{
	sharesys->AddNatives(myself, g_Natives);
	sharesys->RegisterLibrary(myself, "mcbridge");
	g_fwdMessage = forwards->CreateForward("MC_OnMessage", ET_Ignore, 1, nullptr, Param_String);
}

void McBridge::SDK_OnUnload()
{
	smutils->RemoveGameFrameHook(on_game_frame);
	if (g_hook)
		UnhookWindowsHookEx(g_hook);
	g_hook = nullptr;
	g_run = false;
	close_ws();
	if (g_thread.joinable())
		g_thread.join();
	if (g_fwdMessage)
		forwards->ReleaseForward(g_fwdMessage);
	g_fwdMessage = nullptr;
	if (g_session)
		WinHttpCloseHandle(g_session);
	g_session = nullptr;
	if (g_pose)
		UnmapViewOfFile((void *)g_pose);
	if (g_poseMap)
		CloseHandle(g_poseMap);
	g_pose = nullptr;
	g_poseMap = nullptr;
}
