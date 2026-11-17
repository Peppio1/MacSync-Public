# Finder layout without GUI scripting or Apple Events.
from pathlib import Path
app = Path(defines["app"]).resolve()
guide = Path(defines["guide"]).resolve()
graphics = Path(defines["graphics"]).resolve()
format = "UDZO"
filesystem = "HFS+"
files = [str(app), (str(guide), "Guida installazione.html")]
symlinks = {"Applications": "/Applications"}
# Never write FinderInfo or a resource fork onto a signed .app bundle.
# Finder can hide .app by its own preferences; leave the bundle untouched.
hide_extensions = ["Guida installazione.html"]
icon = str(graphics / "MacSync.icns")
background = str(graphics / "MacSync-DMG-Background.png")
window_rect = ((100, 100), (720, 430))
default_view = "icon-view"
arrange_by = None
icon_size = 104
text_size = 13
icon_locations = {"MacSync.app": (190, 207), "Applications": (530, 207), "Guida installazione.html": (580, 365)}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
