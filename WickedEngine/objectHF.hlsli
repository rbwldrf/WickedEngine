#ifndef _OBJECTSHADER_HF_
#define _OBJECTSHADER_HF_

#if !(defined(TILEDFORWARD) && !defined(TRANSPARENT))
#define DISABLE_ALPHATEST
#endif

#ifdef TRANSPARENT
#define DISABLE_TRANSPARENT_SHADOWMAP
#endif

#include "globals.hlsli"
#include "objectInputLayoutHF.hlsli"
#include "windHF.hlsli"
#include "ditherHF.hlsli"
#include "tangentComputeHF.hlsli"
#include "depthConvertHF.hlsli"
#include "fogHF.hlsli"
#include "brdf.hlsli"
#include "packHF.hlsli"
#include "lightingHF.hlsli"

// UNIFORMS
//////////////////

CBUFFER(MaterialCB, CBSLOT_RENDERER_MATERIAL)
{
	float4		g_xMat_baseColor;
	float4		g_xMat_texMulAdd;
	float		g_xMat_roughness;
	float		g_xMat_reflectance;
	float		g_xMat_metalness;
	float		g_xMat_emissive;
	float		g_xMat_refractionIndex;
	float		g_xMat_subsurfaceScattering;
	float		g_xMat_normalMapStrength;
	float		g_xMat_parallaxOcclusionMapping;
};

// DEFINITIONS
//////////////////

#define xBaseColorMap			texture_0
#define xNormalMap				texture_1
#define xRoughnessMap			texture_2
#define xReflectanceMap			texture_3
#define xMetalnessMap			texture_4
#define xDisplacementMap		texture_5

#define xReflection				texture_6
#define xRefraction				texture_7
#define	xWaterRipples			texture_8


struct PixelInputType_Simple
{
	float4 pos								: SV_POSITION;
	float  clip								: SV_ClipDistance0;
	float2 tex								: TEXCOORD0;
	nointerpolation float  dither			: DITHER;
	nointerpolation float3 instanceColor	: INSTANCECOLOR;
};
struct PixelInputType
{
	float4 pos								: SV_POSITION;
	float  clip								: SV_ClipDistance0;
	float2 tex								: TEXCOORD0;
	nointerpolation float  dither			: DITHER;
	nointerpolation float3 instanceColor	: INSTANCECOLOR;
	float3 nor								: NORMAL;
	float4 pos2D							: SCREENPOSITION;
	float3 pos3D							: WORLDPOSITION;
	float4 pos2DPrev						: SCREENPOSITIONPREV;
	float4 ReflectionMapSamplingPos			: TEXCOORD1;
	float2 nor2D							: NORMAL2D;
};

struct GBUFFEROutputType
{
	float4 g0	: SV_TARGET0;		// texture_gbuffer0
	float4 g1	: SV_TARGET1;		// texture_gbuffer1
	float4 g2	: SV_TARGET2;		// texture_gbuffer2
	float4 g3	: SV_TARGET3;		// texture_gbuffer3
};
inline GBUFFEROutputType CreateGbuffer(in float4 color, in Surface surface, in float2 velocity)
{
	GBUFFEROutputType Out;
	Out.g0 = float4(color.rgb, 1);														/*FORMAT_R8G8B8A8_UNORM*/
	Out.g1 = float4(encode(surface.N), velocity);										/*FORMAT_R16G16B16_FLOAT*/
	Out.g2 = float4(0, 0, surface.sss, surface.emissive);								/*FORMAT_R8G8B8A8_UNORM*/
	Out.g3 = float4(surface.roughness, surface.reflectance, surface.metalness, 1);		/*FORMAT_R8G8B8A8_UNORM*/
	return Out;
}

struct GBUFFEROutputType_Thin
{
	float4 g0	: SV_TARGET0;		// texture_gbuffer0
	float4 g1	: SV_TARGET1;		// texture_gbuffer1
};
inline GBUFFEROutputType_Thin CreateGbuffer_Thin(in float4 color, in Surface surface, in float2 velocity)
{
	GBUFFEROutputType_Thin Out;
	Out.g0 = color;																		/*FORMAT_R16G16B16_FLOAT*/
	Out.g1 = float4(encode(surface.N), velocity);										/*FORMAT_R16G16B16_FLOAT*/
	return Out;
}


// METHODS
////////////

inline void NormalMapping(in float2 UV, in float3 V, inout float3 N, in float3x3 TBN, inout float3 bumpColor)
{
	float4 nortex = xNormalMap.Sample(sampler_objectshader, UV);
	bumpColor = 2.0f * nortex.rgb - 1.0f;
	bumpColor *= nortex.a;
	N = normalize(lerp(N, mul(bumpColor, TBN), g_xMat_normalMapStrength));
	bumpColor *= g_xMat_normalMapStrength;
}

inline void SpecularAA(in float3 N, inout float roughness)
{
	[branch]
	if (g_xWorld_SpecularAA > 0)
	{
		float3 ddxN = ddx_coarse(N);
		float3 ddyN = ddy_coarse(N);
		float curve = pow(max(dot(ddxN, ddxN), dot(ddyN, ddyN)), 1 - g_xWorld_SpecularAA);
		roughness = max(roughness, curve);
	}
}

inline float3 PlanarReflection(in float2 UV, in float2 reflectionUV, in Surface surface)
{
	float4 colorReflection = xReflection.SampleLevel(sampler_linear_clamp, reflectionUV + surface.N.xz*g_xMat_normalMapStrength, 0);
	return colorReflection.rgb * surface.F;
}

#define NUM_PARALLAX_OCCLUSION_STEPS 32
inline void ParallaxOcclusionMapping(inout float2 UV, in float3 V, in float3x3 TBN)
{
	V = mul(TBN, V);
	float layerHeight = 1.0 / NUM_PARALLAX_OCCLUSION_STEPS;
	float curLayerHeight = 0;
	float2 dtex = g_xMat_parallaxOcclusionMapping * V.xy / NUM_PARALLAX_OCCLUSION_STEPS;
	float2 currentTextureCoords = UV;
	float2 derivX = ddx_coarse(UV);
	float2 derivY = ddy_coarse(UV);
	float heightFromTexture = 1 - xDisplacementMap.SampleGrad(sampler_linear_wrap, currentTextureCoords, derivX, derivY).r;
	uint iter = 0;
	[loop]
	while (heightFromTexture > curLayerHeight && iter < NUM_PARALLAX_OCCLUSION_STEPS)
	{
		curLayerHeight += layerHeight;
		currentTextureCoords -= dtex;
		heightFromTexture = 1 - xDisplacementMap.SampleGrad(sampler_linear_wrap, currentTextureCoords, derivX, derivY).r;
		iter++;
	}
	float2 prevTCoords = currentTextureCoords + dtex;
	float nextH = heightFromTexture - curLayerHeight;
	float prevH = 1 - xDisplacementMap.SampleGrad(sampler_linear_wrap, prevTCoords, derivX, derivY).r - curLayerHeight + layerHeight;
	float weight = nextH / (nextH - prevH);
	float2 finalTexCoords = prevTCoords * weight + currentTextureCoords * (1.0 - weight);
	UV = finalTexCoords;
}

inline void Refraction(in float2 ScreenCoord, in float2 normal2D, in float3 bumpColor, in Surface surface, inout float4 color)
{
	float2 size;
	float mipLevels;
	xRefraction.GetDimensions(0, size.x, size.y, mipLevels);
	float2 perturbatedRefrTexCoords = ScreenCoord.xy + (normal2D + bumpColor.rg) * g_xMat_refractionIndex;
	float4 refractiveColor = xRefraction.SampleLevel(sampler_linear_clamp, perturbatedRefrTexCoords, (g_xWorld_AdvancedRefractions ? surface.roughness * mipLevels : 0));
	surface.albedo.rgb = lerp(refractiveColor.rgb, surface.albedo.rgb, color.a);
	color.a = 1;
}


inline void ForwardLighting(in Surface surface, inout float3 diffuse, out float3 specular)
{
	specular = 0;
	diffuse = 0;

	specular += surface.baseColor.rgb * GetEmissive(surface.emissive);

#ifndef DISABLE_ENVMAPS
	float envMapMIP = surface.roughness * g_xWorld_EnvProbeMipCount;
	specular = max(0, EnvironmentReflection_Global(surface.P, surface.R, envMapMIP) * surface.F);
#endif // DISABLE_ENVMAPS

	[loop]
	for (uint iterator = 0; iterator < g_xFrame_LightArrayCount; iterator++)
	{
		ShaderEntityType light = EntityArray[g_xFrame_LightArrayOffset + iterator];

		LightingResult result = (LightingResult)0;

		switch (light.type)
		{
		case ENTITY_TYPE_DIRECTIONALLIGHT:
		{
			result = DirectionalLight(light, surface);
		}
		break;
		case ENTITY_TYPE_POINTLIGHT:
		{
			result = PointLight(light, surface);
		}
		break;
		case ENTITY_TYPE_SPOTLIGHT:
		{
			result = SpotLight(light, surface);
		}
		break;
		case ENTITY_TYPE_SPHERELIGHT:
		{
			result = SphereLight(light, surface);
		}
		break;
		case ENTITY_TYPE_DISCLIGHT:
		{
			result = DiscLight(light, surface);
		}
		break;
		case ENTITY_TYPE_RECTANGLELIGHT:
		{
			result = RectangleLight(light, surface);
		}
		break;
		case ENTITY_TYPE_TUBELIGHT:
		{
			result = TubeLight(light, surface);
		}
		break;
		}

		diffuse += max(0.0f, result.diffuse);
		specular += max(0.0f, result.specular);
	}
}


inline void TiledLighting(in float2 pixel, in Surface surface, inout float3 diffuse, out float3 specular)
{
	uint2 tileIndex = uint2(floor(pixel / TILED_CULLING_BLOCKSIZE));
	uint startOffset = flatten2D(tileIndex, g_xWorld_EntityCullingTileCount.xy) * MAX_SHADER_ENTITY_COUNT_PER_TILE;
	uint arrayProperties = EntityIndexList[startOffset];
	uint arrayLength = arrayProperties & 0x000FFFFF; // count of every element in the tile
	uint decalCount = (arrayProperties & 0xFF000000) >> 24; // count of just the decals in the tile
	uint envmapCount = (arrayProperties & 0x00F00000) >> 20; // count of just the envmaps in the tile
	startOffset += 1; // first element was the itemcount
	uint iterator = 0;

	specular = 0;
	diffuse = 0;

	specular += surface.baseColor.rgb * GetEmissive(surface.emissive);

#ifdef DISABLE_DECALS
	// decals are disabled, set the iterator to skip decals:
	iterator = decalCount;
#else
	// decals are enabled, loop through them first:
	float4 decalAccumulation = 0;
	float3 P_dx = ddx_coarse(surface.P);
	float3 P_dy = ddy_coarse(surface.P);

	[loop]
	for (; iterator < decalCount; ++iterator)
	{
		ShaderEntityType decal = EntityArray[EntityIndexList[startOffset + iterator]];

		float4x4 decalProjection = MatrixArray[decal.additionalData_index];
		float3 clipSpacePos = mul(float4(surface.P, 1), decalProjection).xyz;
		float3 uvw = clipSpacePos.xyz*float3(0.5f, -0.5f, 0.5f) + 0.5f;
		[branch]
		if (!any(uvw - saturate(uvw)))
		{
			// mipmapping needs to be performed by hand:
			float2 decalDX = mul(P_dx, (float3x3)decalProjection).xy * decal.texMulAdd.xy;
			float2 decalDY = mul(P_dy, (float3x3)decalProjection).xy * decal.texMulAdd.xy;
			float4 decalColor = texture_decalatlas.SampleGrad(sampler_objectshader, uvw.xy*decal.texMulAdd.xy + decal.texMulAdd.zw, decalDX, decalDY);
			// blend out if close to cube Z:
			float edgeBlend = 1 - pow(saturate(abs(clipSpacePos.z)), 8);
			decalColor.a *= edgeBlend;
			decalColor *= decal.GetColor();
			// apply emissive:
			specular += max(0, decalColor.rgb * decal.GetEmissive() * edgeBlend);
			// perform manual blending of decals:
			//  NOTE: they are sorted top-to-bottom, but blending is performed bottom-to-top
			decalAccumulation.rgb = (1 - decalAccumulation.a) * (decalColor.a*decalColor.rgb) + decalAccumulation.rgb;
			decalAccumulation.a = decalColor.a + (1 - decalColor.a) * decalAccumulation.a;
			// if the accumulation reached 1, we skip the rest of the decals:
			iterator = decalAccumulation.a < 1 ? iterator : decalCount - 1;
		}
	}

	surface.albedo.rgb = lerp(surface.albedo.rgb, decalAccumulation.rgb, decalAccumulation.a);
#endif // DISABLE_DECALS


#ifndef DISABLE_ENVMAPS
	// Apply environment maps:

	float4 envmapAccumulation = 0;
	float envMapMIP = surface.roughness * g_xWorld_EnvProbeMipCount;

#ifdef DISABLE_LOCALENVPMAPS
	// local envmaps are disabled, set iterator to skip:
	iterator += envmapCount;
#else
	// local envmaps are enabled, loop through them and apply:
	uint envmapArrayEnd = iterator + envmapCount;

	[loop]
	for (; iterator < envmapArrayEnd; ++iterator)
	{
		ShaderEntityType probe = EntityArray[EntityIndexList[startOffset + iterator]];

		float4x4 probeProjection = MatrixArray[probe.additionalData_index];
		float3 clipSpacePos = mul(float4(surface.P, 1), probeProjection).xyz;
		float3 uvw = clipSpacePos.xyz*float3(0.5f, -0.5f, 0.5f) + 0.5f;
		[branch]
		if (!any(uvw - saturate(uvw)))
		{
			float4 envmapColor = EnvironmentReflection_Local(probe, probeProjection, clipSpacePos, surface.P, surface.R, envMapMIP);
			// perform manual blending of probes:
			//  NOTE: they are sorted top-to-bottom, but blending is performed bottom-to-top
			envmapAccumulation.rgb = (1 - envmapAccumulation.a) * (envmapColor.a * envmapColor.rgb) + envmapAccumulation.rgb;
			envmapAccumulation.a = envmapColor.a + (1 - envmapColor.a) * envmapAccumulation.a;
			// if the accumulation reached 1, we skip the rest of the probes:
			iterator = envmapAccumulation.a < 1 ? iterator : envmapCount - 1;
		}
	}
#endif // DISABLE_LOCALENVPMAPS

	// Apply global envmap where there is no local envmap information:
	envmapAccumulation.rgb = lerp(EnvironmentReflection_Global(surface.P, surface.R, envMapMIP), envmapAccumulation.rgb, envmapAccumulation.a);

	specular += max(0, envmapAccumulation.rgb * surface.F);

#endif // DISABLE_ENVMAPS


	// And finally loop through and apply lights:
	[loop]
	for (; iterator < arrayLength; iterator++)
	{
		ShaderEntityType light = EntityArray[EntityIndexList[startOffset + iterator]];

		LightingResult result = (LightingResult)0;

		switch (light.type)
		{
		case ENTITY_TYPE_DIRECTIONALLIGHT:
		{
			result = DirectionalLight(light, surface);
		}
		break;
		case ENTITY_TYPE_POINTLIGHT:
		{
			result = PointLight(light, surface);
		}
		break;
		case ENTITY_TYPE_SPOTLIGHT:
		{
			result = SpotLight(light, surface);
		}
		break;
		case ENTITY_TYPE_SPHERELIGHT:
		{
			result = SphereLight(light, surface);
		}
		break;
		case ENTITY_TYPE_DISCLIGHT:
		{
			result = DiscLight(light, surface);
		}
		break;
		case ENTITY_TYPE_RECTANGLELIGHT:
		{
			result = RectangleLight(light, surface);
		}
		break;
		case ENTITY_TYPE_TUBELIGHT:
		{
			result = TubeLight(light, surface);
		}
		break;
		}

		diffuse += max(0.0f, result.diffuse);
		specular += max(0.0f, result.specular);
	}
}

inline void ApplyLighting(in Surface surface, in float3 diffuse, in float3 specular, in float ao, in float opacity, inout float4 color)
{
	color.rgb = lerp(1, GetAmbientColor() * ao + diffuse, opacity) * surface.albedo + specular;
}

inline void ApplyFog(in float dist, inout float4 color)
{
	color.rgb = lerp(color.rgb, GetHorizonColor(), GetFog(dist));
}


// OBJECT SHADER PROTOTYPE
///////////////////////////

#if defined(COMPILE_OBJECTSHADER_PS)

// Possible switches:
//	ALPHATESTONLY		-	assemble object shader for depth only rendering + alpha test
//	TEXTUREONLY			-	assemble object shader for rendering only with base textures, no lighting
//	DEFERRED			-	assemble object shader for deferred rendering
//	FORWARD				-	assemble object shader for forward rendering
//	TILEDFORWARD		-	assemble object shader for tiled forward rendering
//	TRANSPARENT			-	assemble object shader for forward or tile forward transparent rendering
//	ENVMAPRENDERING		-	modify object shader for envmap rendering
//	NORMALMAP			-	include normal mapping computation
//	PLANARREFLECTION	-	include planar reflection sampling
//	POM					-	include parallax occlusion mapping computation
//	WATER				-	include specialized water shader code
//	BLACKOUT			-	include specialized blackout shader code

#if defined(ALPHATESTONLY) || defined(TEXTUREONLY)
#define SIMPLE_INPUT
#endif // APLHATESTONLY

#ifdef SIMPLE_INPUT
#define PIXELINPUT PixelInputType_Simple
#else
#define PIXELINPUT PixelInputType
#endif // SIMPLE_INPUT


// entry point:
#if defined(ALPHATESTONLY)
void main(PIXELINPUT input)
#elif defined(TEXTUREONLY)
float4 main(PIXELINPUT input) : SV_TARGET
#elif defined(TRANSPARENT)
float4 main(PIXELINPUT input) : SV_TARGET
#elif defined(ENVMAPRENDERING)
float4 main(PSIn input) : SV_TARGET
#elif defined(DEFERRED)
GBUFFEROutputType main(PIXELINPUT input)
#elif defined(FORWARD)
GBUFFEROutputType_Thin main(PIXELINPUT input)
#elif defined(TILEDFORWARD)
[earlydepthstencil]
GBUFFEROutputType_Thin main(PIXELINPUT input)
#endif // ALPHATESTONLY



// shader base:
{
	float2 pixel = input.pos.xy;

#if !(defined(TILEDFORWARD) && !defined(TRANSPARENT)) && !defined(ENVMAPRENDERING)
	// apply dithering:
	clip(dither(pixel) - input.dither);
#endif



	float2 UV = input.tex * g_xMat_texMulAdd.xy + g_xMat_texMulAdd.zw;

	Surface surface;

#ifndef SIMPLE_INPUT
	surface.P = input.pos3D;
	surface.V = g_xCamera_CamPos - surface.P;
	float dist = length(surface.V);
	surface.V /= dist;
	surface.N = normalize(input.nor);

	float3 T, B;
	float3x3 TBN = compute_tangent_frame(surface.N, surface.P, UV, T, B);
#endif // SIMPLE_INPUT

#ifdef POM
	ParallaxOcclusionMapping(UV, surface.V, TBN);
#endif // POM

	float4 color = g_xMat_baseColor * float4(input.instanceColor, 1) * xBaseColorMap.Sample(sampler_objectshader, UV);
	color.rgb = DEGAMMA(color.rgb);
	ALPHATEST(color.a);

#ifndef SIMPLE_INPUT
	float3 diffuse = 0;
	float3 specular = 0;
	float3 bumpColor = 0;
	float opacity = color.a;
	float depth = input.pos.z;
	float ao = 1;
#ifndef ENVMAPRENDERING
	float lineardepth = input.pos2D.w;
	float2 refUV = float2(1, -1)*input.ReflectionMapSamplingPos.xy / input.ReflectionMapSamplingPos.w * 0.5f + 0.5f;
	float2 ScreenCoord = float2(1, -1) * input.pos2D.xy / input.pos2D.w * 0.5f + 0.5f;
	float2 velocity = ((input.pos2DPrev.xy / input.pos2DPrev.w - g_xFrame_TemporalAAJitterPrev) - (input.pos2D.xy / input.pos2D.w - g_xFrame_TemporalAAJitter)) * float2(0.5f, -0.5f);
#endif // ENVMAPRENDERING
#endif // SIMPLE_INPUT

#ifdef NORMALMAP
	NormalMapping(UV, surface.P, surface.N, TBN, bumpColor);
#endif // NORMALMAP

	surface = CreateSurface(surface.P, surface.N, surface.V, color,
		g_xMat_reflectance * xReflectanceMap.Sample(sampler_objectshader, UV).r,
		g_xMat_metalness * xMetalnessMap.Sample(sampler_objectshader, UV).r,
		g_xMat_roughness * xRoughnessMap.Sample(sampler_objectshader, UV).r,
		g_xMat_emissive, g_xMat_subsurfaceScattering);


#ifndef SIMPLE_INPUT


#ifdef WATER
	color.a = 1;

	//NORMALMAP
	float2 bumpColor0 = 0;
	float2 bumpColor1 = 0;
	float2 bumpColor2 = 0;
	bumpColor0 = 2.0f * xNormalMap.Sample(sampler_objectshader, UV - g_xMat_texMulAdd.ww).rg - 1.0f;
	bumpColor1 = 2.0f * xNormalMap.Sample(sampler_objectshader, UV + g_xMat_texMulAdd.zw).rg - 1.0f;
	bumpColor2 = xWaterRipples.Sample(sampler_objectshader, ScreenCoord).rg;
	bumpColor = float3(bumpColor0 + bumpColor1 + bumpColor2, 1)  * g_xMat_refractionIndex;
	surface.N = normalize(lerp(surface.N, mul(normalize(bumpColor), TBN), g_xMat_normalMapStrength));
	bumpColor *= g_xMat_normalMapStrength;

	//REFLECTION
	float2 RefTex = float2(1, -1)*input.ReflectionMapSamplingPos.xy / input.ReflectionMapSamplingPos.w / 2.0f + 0.5f;
	float4 reflectiveColor = xReflection.SampleLevel(sampler_linear_mirror, RefTex + bumpColor.rg, 0);


	//REFRACTION 
	float2 perturbatedRefrTexCoords = ScreenCoord.xy + bumpColor.rg;
	float refDepth = (texture_lineardepth.Sample(sampler_linear_mirror, ScreenCoord));
	float3 refractiveColor = xRefraction.SampleLevel(sampler_linear_mirror, perturbatedRefrTexCoords, 0).rgb;
	float mod = saturate(0.05*(refDepth - lineardepth));
	refractiveColor = lerp(refractiveColor, surface.baseColor.rgb, mod).rgb;

	//FRESNEL TERM
	float3 fresnelTerm = F_Fresnel(surface.f0, surface.NdotV);
	surface.albedo.rgb = lerp(refractiveColor, reflectiveColor.rgb, fresnelTerm);
#endif // WATER



	SpecularAA(surface.N, surface.roughness);

#ifdef TRANSPARENT
	Refraction(ScreenCoord, input.nor2D, bumpColor, surface, color);
#endif // TRANSPARENT

#ifdef FORWARD
	ForwardLighting(surface, diffuse, specular);
#endif // FORWARD

#ifdef TILEDFORWARD
	TiledLighting(pixel, surface, diffuse, specular);
	VoxelRadiance(surface, diffuse, specular, ao);
#endif // TILEDFORWARD

#ifdef PLANARREFLECTION
	specular = max(specular, PlanarReflection(UV, refUV, surface));
#endif

	ApplyLighting(surface, diffuse, specular, ao, opacity, color);

#ifdef WATER
	// SOFT EDGE
	float fade = saturate(0.3 * abs(refDepth - lineardepth));
	color.a *= fade;
#endif // WATER

	ApplyFog(dist, color);


#endif // SIMPLE_INPUT


#ifdef TEXTUREONLY
	color.rgb += color.rgb * GetEmissive(surface.emissive);
#endif // TEXTUREONLY


#ifdef BLACKOUT
	color = float4(0, 0, 0, 1);
#endif


	// return point:
#if defined(TRANSPARENT) || defined(TEXTUREONLY) || defined(ENVMAPRENDERING)
	return color;
#else
#if defined(DEFERRED)	
	return CreateGbuffer(color, surface, velocity);
#elif defined(FORWARD) || defined(TILEDFORWARD)
	return CreateGbuffer_Thin(color, surface, velocity);
#endif // DEFERRED
#endif // TRANSPARENT

}


#endif // COMPILE_OBJECTSHADER_PS



//// MACROS
//////////////
//
//#define OBJECT_PS_MAKE_SIMPLE												\
//	float2 UV = input.tex * g_xMat_texMulAdd.xy + g_xMat_texMulAdd.zw;		\
//	float4 color = g_xMat_baseColor * float4(input.instanceColor, 1) * xBaseColorMap.Sample(sampler_objectshader, UV);	\
//	color.rgb = DEGAMMA(color.rgb);											\
//	ALPHATEST(color.a);														\
//	float opacity = color.a;												\
//	float emissive = g_xMat_emissive;										\
//	float2 pixel = input.pos.xy;
//
//
//#define OBJECT_PS_MAKE_COMMON												\
//	OBJECT_PS_MAKE_SIMPLE													\
//	float3 diffuse = 0;														\
//	float3 specular = 0;													\
//	float3 V = g_xCamera_CamPos - input.pos3D;								\
//	float dist = length(V);													\
//	V /= dist;																\
//	Surface surface = CreateSurface(input.pos3D, normalize(input.nor), V, color,	\
//		g_xMat_reflectance * xReflectanceMap.Sample(sampler_objectshader, UV).r,	\
//		g_xMat_metalness * xMetalnessMap.Sample(sampler_objectshader, UV).r,		\
//		g_xMat_roughness * xRoughnessMap.Sample(sampler_objectshader, UV).r,		\
//		emissive, g_xMat_subsurfaceScattering);										\
//	float3 bumpColor = 0;													\
//	float depth = input.pos.z;												\
//	float ao = 1;
//
//#define OBJECT_PS_MAKE																								\
//	OBJECT_PS_MAKE_COMMON																							\
//	float lineardepth = input.pos2D.w;																				\
//	float2 refUV = float2(1, -1)*input.ReflectionMapSamplingPos.xy / input.ReflectionMapSamplingPos.w * 0.5f + 0.5f;\
//	float2 ScreenCoord = float2(1, -1) * input.pos2D.xy / input.pos2D.w * 0.5f + 0.5f;								\
//	float2 velocity = ((input.pos2DPrev.xy/input.pos2DPrev.w - g_xFrame_TemporalAAJitterPrev) - (input.pos2D.xy/input.pos2D.w - g_xFrame_TemporalAAJitter)) * float2(0.5f, -0.5f);
//
//#define OBJECT_PS_COMPUTETANGENTSPACE										\
//	float3 T, B;															\
//	float3x3 TBN = compute_tangent_frame(surface.N, surface.P, UV, T, B);
//
//#define OBJECT_PS_NORMALMAPPING												\
//	NormalMapping(UV, surface.P, surface.N, TBN, bumpColor);				\
//	surface.Update();
//
//#define OBJECT_PS_PARALLAXOCCLUSIONMAPPING									\
//	ParallaxOcclusionMapping(UV, surface.V, TBN);
//
//#define OBJECT_PS_SPECULARANTIALIASING										\
//	SpecularAA(surface.N, surface.roughness);
//
//#define OBJECT_PS_REFRACTION																						\
//	Refraction(ScreenCoord, input.nor2D, bumpColor, surface, color);
//
//#define OBJECT_PS_LIGHT_FORWARD																						\
//	ForwardLighting(surface, diffuse, specular);
//
//#define OBJECT_PS_LIGHT_TILED																						\
//	TiledLighting(pixel, surface, diffuse, specular);
//
//#define OBJECT_PS_VOXELRADIANCE																						\
//	VoxelRadiance(surface, diffuse, specular, ao);
//
//#define OBJECT_PS_LIGHT_END																							\
//	color.rgb = lerp(1, GetAmbientColor() * ao + diffuse, opacity) * surface.albedo + specular;
//
//#define OBJECT_PS_DITHER																							\
//	clip(dither(input.pos.xy) - input.dither);
//
//#define OBJECT_PS_PLANARREFLECTIONS																					\
//	specular = max(specular, PlanarReflection(UV, refUV, surface));
//
//#define OBJECT_PS_FOG																								\
//	color.rgb = applyFog(color.rgb, getFog(dist));
//
//#define OBJECT_PS_OUT_GBUFFER																						\
//	GBUFFEROutputType Out;																							\
//	Out.g0 = float4(color.rgb, 1);														/*FORMAT_R8G8B8A8_UNORM*/	\
//	Out.g1 = float4(encode(surface.N), velocity);										/*FORMAT_R16G16B16_FLOAT*/	\
//	Out.g2 = float4(0, 0, surface.sss, surface.emissive);								/*FORMAT_R8G8B8A8_UNORM*/	\
//	Out.g3 = float4(surface.roughness, surface.reflectance, surface.metalness, ao);		/*FORMAT_R8G8B8A8_UNORM*/	\
//	return Out;
//
//#define OBJECT_PS_OUT_FORWARD																						\
//	GBUFFEROutputType_Thin Out;																						\
//	Out.g0 = color;																		/*FORMAT_R16G16B16_FLOAT*/	\
//	Out.g1 = float4(encode(surface.N), velocity);										/*FORMAT_R16G16B16_FLOAT*/	\
//	return Out;
//
//#define OBJECT_PS_OUT_FORWARD_SIMPLE																				\
//	return color;

#endif // _OBJECTSHADER_HF_