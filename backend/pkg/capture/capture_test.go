package capture

import (
	"testing"

	"ambxst/backend/pkg/axmon"
)

func TestCropScaleUsesMatchingAxes(t *testing.T) {
	monitor := &axmon.Monitor{
		Name:   "DP-1",
		Width:  1920,
		Height: 1080,
		Scale:  1,
	}

	gotX, gotY := cropScales(monitor, 3840, 2160)
	if gotX != 2 || gotY != 2 {
		t.Fatalf("normal crop scale: got %v,%v want 2,2", gotX, gotY)
	}
}

func TestCropScaleSwapsAxesForRotatedOutput(t *testing.T) {
	monitor := &axmon.Monitor{
		Name:   "HDMI-A-1",
		Width:  1080,
		Height: 1920,
		Scale:  2,
		Metadata: map[string]interface{}{
			"transform": float64(1),
		},
	}

	// The upright frame is 1920x1080 even though the rotated monitor is
	// reported as 1080x1920 by axctl.
	gotX, gotY := cropScales(monitor, 3840, 2160)
	if gotX != 2 || gotY != 2 {
		t.Fatalf("rotated crop scale: got %v,%v want 2,2", gotX, gotY)
	}
}

func TestCropScaleFallsBackToMonitorScaleWithoutFrameDimensions(t *testing.T) {
	monitor := &axmon.Monitor{Name: "eDP-1", Width: 1920, Height: 1080, Scale: 1.5}

	gotX, gotY := cropScales(monitor, 0, 0)
	if gotX != 1.5 || gotY != 1.5 {
		t.Fatalf("fallback crop scale: got %v,%v want 1.5,1.5", gotX, gotY)
	}
}
