//----------------------------------------------------------------------------
//
//  AgentDVR addition to Emgu.CV.Extern (not part of upstream Emgu CV).
//  Every build script copies patches/agentdvr_*.cpp to Emgu.CV.Extern/imgproc/,
//  whose *.cpp files Emgu's CMakeLists globs into cvextern.
//
//  cveAgentFindMotionBoxes: the tracking motion detector's object acquisition
//  (Agent's TrackerBase.FindNewTrackedObjects) in one call - Canny edges of the
//  foreground mask, external contours, each simplified with approxPolyDP and
//  boxed, boxes outside the size limits dropped. Through Emgu's API every contour
//  cost a VectorOfPoint plus InputArray/OutputArray wrappers for arcLength,
//  approxPolyDP and boundingRect (~5 finalizable wrappers, ~12 P/Invokes), and a
//  noisy mask gives 50-200 contours per tick. Agent probes for the export and
//  falls back to the managed path when an older cvextern lacks it.
//
//----------------------------------------------------------------------------

#include "imgproc_c.h"

// Writes the boxes (in contour order, the order the managed path visited them) into
// boxes[0..maxBoxes) and returns how many there are; a result above maxBoxes means the
// buffer was too small and the call should be repeated with a bigger one. A box is kept
// when minWidth < width < maxWidth and minHeight < height < maxHeight (strict, as before).
// Returns -1 on an OpenCV error, recorded for CvInvoke.CheckError().
CVAPI(int) cveAgentFindMotionBoxes(
	uchar* mask, int maskStep, int width, int height,
	double cannyThreshold1, double cannyThreshold2, double approxEpsilonFactor,
	int minWidth, int minHeight, int maxWidth, int maxHeight,
	cv::Rect* boxes, int maxBoxes)
{
	try
	{
		cv::Mat src(height, width, CV_8UC1, mask, (size_t)maskStep);
		cv::Mat edges;
		cv::Canny(src, edges, cannyThreshold1, cannyThreshold2);

		std::vector<std::vector<cv::Point>> contours;
		cv::findContours(edges, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

		std::vector<cv::Point> approx;
		int n = 0;
		for (const auto& contour : contours)
		{
			cv::approxPolyDP(contour, approx, cv::arcLength(contour, true) * approxEpsilonFactor, true);
			cv::Rect r = cv::boundingRect(approx);
			if (r.width < maxWidth && r.height < maxHeight && r.width > minWidth && r.height > minHeight)
			{
				if (n < maxBoxes)
					boxes[n] = r;
				n++;
			}
		}
		return n;
	}
	CVAPI_CATCH_CV_ERRORS(-1)
}
