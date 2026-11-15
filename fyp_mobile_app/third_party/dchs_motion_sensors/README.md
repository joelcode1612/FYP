# SiteWise touch-only panorama compatibility layer

`panorama_viewer` imports `dchs_motion_sensors` even when its default
`SensorControl.none` mode is used. SiteWise's two panorama screens only use
touch drag and pinch-to-zoom; they do not request or configure device-motion
control.

This small local package supplies the API surface needed by `panorama_viewer`
without declaring an Android or iOS plugin. Its sensor streams are empty by
design. If SiteWise later adds device-motion panorama navigation, replace this
package with a maintained real sensor implementation and add device testing.
