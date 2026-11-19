from pathlib import Path

files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
background = str(Path(defines["assets"]) / "installer-background.png")

filesystem = "HFS+"
format = "UDZO"
window_rect = ((160, 110), (640, 515))
default_view = "icon-view"
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_tab_view = False
show_pathbar = False
icon_size = 104
text_size = 13
icon_locations = {"FocusApp.app": (155, 184), "Applications": (485, 184)}
