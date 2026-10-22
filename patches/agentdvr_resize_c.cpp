//----------------------------------------------------------------------------
//
//  AgentDVR addition to Emgu.CV.Extern (not part of upstream Emgu CV).
//  Every build script copies this file to Emgu.CV.Extern/imgproc/, whose *.cpp
//  files Emgu's CMakeLists globs into cvextern, so it needs no CMake changes.
//
//  cveAgentResizeI420Region: crops a region out of a packed I420 frame and scales
//  it into a region of another, one cv::resize per plane - the native body of
//  Agent's YuvResizer.ResizeRegionInto (every compositor tile, every frame).
//  Through Emgu's managed API each plane cost two Mat headers plus an
//  InputArray/OutputArray (4 finalizable managed wrappers, 4 native allocations
//  and ~11 P/Invokes); here the headers live on the stack: one call per tile,
//  no allocations. Agent probes for the export and falls back to the managed
//  path when an older cvextern lacks it.
//
//----------------------------------------------------------------------------

#include "imgproc_c.h"

static void agentResizePlane(uchar* src, int srcStep, int sx, int sy, int sw, int sh,
	uchar* dst, int dstStep, int dx, int dy, int dw, int dh, int interpolation)
{
	// Headers over the existing buffers (no ownership, no allocation). dst is exactly
	// dw x dh CV_8UC1, so cv::resize's dst.create() keeps writing into the frame.
	cv::Mat s(sh, sw, CV_8UC1, src + (size_t)sy * srcStep + sx, (size_t)srcStep);
	cv::Mat d(dh, dw, CV_8UC1, dst + (size_t)dy * dstStep + dx, (size_t)dstStep);
	cv::resize(s, d, d.size(), 0, 0, interpolation);
}

// Rectangles are in luma pixels and must be even (the caller rounds them); the chroma
// planes use the halved rectangle and bilinear interpolation, as the managed path does.
// Errors are recorded for CvInvoke.CheckError(), like every other cve* export.
CVAPI(void) cveAgentResizeI420Region(
	uchar* srcY, uchar* srcU, uchar* srcV, int srcYStep, int srcUVStep,
	int sx, int sy, int sw, int sh,
	uchar* dstY, uchar* dstU, uchar* dstV, int dstYStep, int dstUVStep,
	int dx, int dy, int dw, int dh,
	int lumaInterpolation)
{
	try
	{
		agentResizePlane(srcY, srcYStep, sx, sy, sw, sh, dstY, dstYStep, dx, dy, dw, dh, lumaInterpolation);

		int csx = sx >> 1, csy = sy >> 1, csw = sw >> 1, csh = sh >> 1;
		int cdx = dx >> 1, cdy = dy >> 1, cdw = dw >> 1, cdh = dh >> 1;
		agentResizePlane(srcU, srcUVStep, csx, csy, csw, csh, dstU, dstUVStep, cdx, cdy, cdw, cdh, cv::INTER_LINEAR);
		agentResizePlane(srcV, srcUVStep, csx, csy, csw, csh, dstV, dstUVStep, cdx, cdy, cdw, cdh, cv::INTER_LINEAR);
	}
	CVAPI_CATCH_CV_ERRORS_VOID
}
