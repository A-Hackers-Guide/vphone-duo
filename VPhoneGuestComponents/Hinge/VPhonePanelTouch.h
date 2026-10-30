#pragma once

// The panel touchscreen service's status, written by the provider in
// backboardd and read by vphoned: {enumerated, service_id, display_uuid, …}.
// vphoned dispatches touches under `service_id` while it is enumerated.
#define VP_PANEL_TOUCH_DOMAIN "com.apple.backboardd"
#define VP_PANEL_TOUCH_STATUS "VPhonePanelTouchStatus"
