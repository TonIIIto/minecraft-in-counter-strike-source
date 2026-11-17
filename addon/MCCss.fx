// Minecraft over Counter-Strike: Source. The MCCss add-on uploads Minecraft's latest frame into MCWORLD / MCDEPTH / MCOVERLAY and
// sets the warp uniforms. world: premultiplied RGBA (alpha 0 where Minecraft drew nothing). overlay: Minecraft's hand + HUD.
#include "ReShade.fxh"

texture MCWorldTex : MCWORLD;
texture MCDepthTex : MCDEPTH;
texture MCOverlayTex : MCOVERLAY;
sampler sWorld { Texture = MCWorldTex; AddressU = CLAMP; AddressV = CLAMP; };
sampler sDepth { Texture = MCDepthTex; MinFilter = POINT; MagFilter = POINT; AddressU = CLAMP; AddressV = CLAMP; };
sampler sOverlay { Texture = MCOverlayTex; AddressU = CLAMP; AddressV = CLAMP; };

// Set true by the add-on only while it has a fresh Minecraft frame and the CS:S camera; otherwise CS:S passes through untouched.
uniform bool McActive = false;
uniform bool Reproject < ui_label = "Re-project to CS:S's camera"; > = true;
uniform bool ShowOverlay < ui_label = "Show Minecraft's hand and hotbar"; > = true;
uniform float WorldOpacity < ui_type = "drag"; ui_min = 0.0; ui_max = 1.0; ui_label = "Minecraft world opacity"; > = 1.0;
uniform float MaxDistance < ui_type = "drag"; ui_min = 20.0; ui_max = 600.0; ui_label = "Largest distance searched (blocks)"; > = 250.0;

// x = near, y = far, z = flags (1: [0,1] depth, 2: rows bottom-up, 4: reversed Z). Set by the add-on.
uniform float3 McPlanes = float3(0.05, 1024.0, 7.0);
// Rows of R_mc^T R_cs (CS:S camera ray -> Minecraft camera ray); WarpTan = tan(CS:S vfov/2), tan(MC vfov/2), Minecraft aspect.
uniform float3 WarpRow0 = float3(1.0, 0.0, 0.0);
uniform float3 WarpRow1 = float3(0.0, 1.0, 0.0);
uniform float3 WarpRow2 = float3(0.0, 0.0, 1.0);
uniform float3 WarpTan = float3(0.75, 0.75, 1.7777);
// CS:S's camera position relative to Minecraft's, in Minecraft's camera space.
uniform float3 WarpT = float3(0.0, 0.0, 0.0);

float mc_linear(float d)
{
	const float n = McPlanes.x, f = McPlanes.y;
	if (d <= 0.0)
		return 1e9;
	return n * f / (n + d * (f - n));
}

float3 PS_Main(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	const float3 host = tex2D(ReShade::BackBuffer, uv).rgb;
	if (!McActive)
		return host;

	// Minecraft's rows are bottom-up: texture v = 0 is the bottom of the picture.
	float2 muv = float2(uv.x, 1.0 - uv.y);
	bool inside = true;
	if (Reproject)
	{
		// March this pixel's ray (in CS:S's current camera) from near to far, moving each point into the camera Minecraft
		// rendered with (rotation + how far the camera moved since). The first point behind Minecraft's surface there is
		// where Minecraft is seen: refine it and sample.
		const float3 ray = float3((uv.x * 2.0 - 1.0) * WarpTan.x * BUFFER_WIDTH * BUFFER_RCP_HEIGHT, (1.0 - uv.y * 2.0) * WarpTan.x, -1.0);
		const float2 mcScale = float2(WarpTan.y * WarpTan.z, WarpTan.y);
		const float zNear = 0.1, zFar = MaxDistance;
		float2 ndc = 0.0;
		inside = false;
		[loop] for (int i = 0; i < 40; ++i)
		{
			const float z = zNear * pow(zFar / zNear, i / 39.0);
			const float3 p = ray * z;
			const float3 pm = float3(dot(WarpRow0, p), dot(WarpRow1, p), dot(WarpRow2, p)) + WarpT;
			if (pm.z > -1e-3)
				continue;
			const float2 n = pm.xy / -pm.z / mcScale;
			if (any(abs(n) > 1.0))
				continue;
			const float zmv = mc_linear(tex2Dlod(sDepth, float4(n * 0.5 + 0.5, 0, 0)).r);
			if (zmv > -pm.z + 0.03)
				continue; // still in front of whatever Minecraft drew there
			// crossed Minecraft's surface: settle on it (fixed-point on the surface point's depth along the ray)
			float zg = z;
			ndc = n;
			[loop] for (int k = 0; k < 4; ++k)
			{
				const float3 pk = ray * zg;
				const float3 mk = float3(dot(WarpRow0, pk), dot(WarpRow1, pk), dot(WarpRow2, pk)) + WarpT;
				if (mk.z > -1e-3)
					break;
				const float2 nk = mk.xy / -mk.z / mcScale;
				if (any(abs(nk) > 1.0))
					break;
				const float zk = mc_linear(tex2Dlod(sDepth, float4(nk * 0.5 + 0.5, 0, 0)).r);
				if (zk > 1e8)
					break;
				ndc = nk;
				const float3 q = float3(nk * mcScale, -1.0) * zk - WarpT;
				zg = -(q.x * WarpRow0.z + q.y * WarpRow1.z + q.z * WarpRow2.z);
			}

			muv = ndc * 0.5 + 0.5;
			inside = true;
			break;
		}
	}

	float4 world = inside ? tex2D(sWorld, muv) : 0.0;
	// The ground and walls of CS:S's map are drawn in Minecraft as magenta blocks. They hide Minecraft blocks behind them (they sit
	// in Minecraft's depth buffer), and here they turn invisible: magenta (R and B alike, G much lower) is keyed out.
	if (world.a > 0.01)
	{
		const float3 c = world.rgb / world.a;
		const float mn = min(c.r, c.b);
		const float key = saturate((mn - c.g) / max(mn, 1e-3));
		const float alike = 1.0 - smoothstep(0.10, 0.30, abs(c.r - c.b) / max(mn, 1e-3));
		const float k = smoothstep(0.40, 0.62, key) * alike * step(0.015, mn);
		world *= 1.0 - k;
	}

	const float cover = world.a * WorldOpacity;
	float3 color = world.rgb * WorldOpacity + host * (1.0 - cover);
	if (ShowOverlay)
	{
		const float4 overlay = tex2D(sOverlay, float2(uv.x, 1.0 - uv.y));
		color = overlay.rgb + color * (1.0 - overlay.a);
	}

	return saturate(color);
}

technique MCCss < ui_tooltip = "Minecraft over CS:S: enabled automatically while the Minecraft link is up."; >
{
	pass Main
	{
		VertexShader = PostProcessVS;
		PixelShader = PS_Main;
	}
}
