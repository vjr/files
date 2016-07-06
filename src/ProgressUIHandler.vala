/***
    Copyright (c) 2007, 2011 Red Hat, Inc.
    Copyright (c) 2013 Julián Unrrein <junrrein@gmail.com>

    This program is free software: you can redistribute it and/or modify it
    under the terms of the GNU Lesser General Public License version 3, as published
    by the Free Software Foundation.

    This program is distributed in the hope that it will be useful, but
    WITHOUT ANY WARRANTY; without even the implied warranties of
    MERCHANTABILITY, SATISFACTORY QUALITY, or FITNESS FOR A PARTICULAR
    PURPOSE. See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along
    with this program. If not, see <http://www.gnu.org/licenses/>.

    Authors: Alexander Larsson <alexl@redhat.com>
             Cosimo Cecchi <cosimoc@redhat.com>
             Julián Unrrein <junrrein@gmail.com>
             Jeremy Wootten <jeremy@elementaryos.org>
***/

/*** One instance of this class is owned by the application and handles UI for file transfers initiated by
 *   of the app windows.  Feedback is provided by a dialog window which appears if a transfer takes longer than
 *   approximately 1 second. The unity launcher is also updated if present and a notification is sent of the
 *   completion of the operation unless it was cancelled by the user. 
***/ 
public class Marlin.Progress.UIHandler : Object {

    private Marlin.Progress.InfoManager manager = null;
#if HAVE_UNITY
    private Marlin.QuicklistHandler quicklist_handler = null;
#endif
    private Gtk.Dialog progress_window = null;
    private Gtk.Widget window_vbox = null;
    private uint active_infos = 0;

    private Gdk.Pixbuf notification_image = null;
    private Gdk.Pixbuf cancelled_image = null;

    private const string ACTION_DETAILS = "details";
    private const string TITLE = _("File Manager Operations");
    private const string ICON_NAME = "system-file-manager";
    private const int ICON_SIZE = 64;
    private const string CANCELLED_ICON_NAME = "dialog-warning";

    private Marlin.Application application;

    public UIHandler (Marlin.Application app) {
        this.manager = new Marlin.Progress.InfoManager ();
        this.application = app;

        manager.new_progress_info.connect ((info) => {
            info.started.connect (progress_info_started_cb);
        });

        var theme = Gtk.IconTheme.get_default ();
        try {
            notification_image = theme.load_icon (ICON_NAME, ICON_SIZE, 0);
            cancelled_image = theme.load_icon (CANCELLED_ICON_NAME, ICON_SIZE, 0);
        } catch (GLib.Error e) {
            warning ("ProgressUIHandler error loading notification images - %s", e.message);
        }
    }

    ~UIHandler () {
        debug ("ProgressUIHandler destruct");
        if (active_infos > 0) {
            warning ("ProgressUIHandler destruct when infos active");
            cancel_all ();
        }
    }

    public void cancel_all () {
        unowned List<Marlin.Progress.Info> infos = this.manager.get_all_infos ();
        foreach (var info in infos) {
            info.cancel ();
        }

    }

    public uint get_active_info_count () {
        return active_infos;
    }
    public unowned List<Marlin.Progress.Info> get_active_info_list () {
        return manager.get_all_infos ();
    }

    private void progress_info_started_cb (Marlin.Progress.Info info) {
        application.hold ();

        if (info == null || !(info is Marlin.Progress.Info) ||
            info.get_is_finished () || info.get_cancellable ().is_cancelled ()) {

            return;
        }

        this.active_infos++;
        info.finished.connect (progress_info_finished_cb);

        var operation_running = false;
        Timeout.add_full (GLib.Priority.LOW, 500, () => {
            if (info == null || !(info is Marlin.Progress.Info) ||
                info.get_is_finished () || info.get_cancellable ().is_cancelled ()) {

                return false;
            }

            if (info.get_is_paused ()) {
                return true;
            } else if (operation_running && !info.get_is_finished ()) {
                add_progress_info_to_window (info);
                return false;
            } else {
                operation_running = true;
                return true;
            }
        });
    }

    private void add_progress_info_to_window (Marlin.Progress.Info info) {
        if (this.active_infos == 1) {
            /* This is the only active operation, present the window */
            add_to_window (info);
            (this.progress_window as Gtk.Window).present ();
        } else if (this.progress_window.visible) {
                add_to_window (info);
        }

#if HAVE_UNITY
        update_unity_launcher (info, true);
#endif
    }

    private void add_to_window (Marlin.Progress.Info info) {
        ensure_window ();

        var progress_widget = new Marlin.Progress.InfoWidget (info);
        (this.window_vbox as Gtk.Box).pack_start (progress_widget, false, false, 6);

        progress_widget.show ();
        if (this.progress_window.visible) {
            (this.progress_window as Gtk.Window).present ();
        }
    }

    private void ensure_window () {
        if (this.progress_window == null) {
            /* This provides an undeletable, unminimisable window in which to show the info widgets */
            this.progress_window = new Gtk.Dialog ();
            this.progress_window.resizable = false;
            this.progress_window.deletable = false;
            this.progress_window.title = _("File Operations");
            this.progress_window.set_wmclass ("file_progress", "Marlin");
            this.progress_window.icon_name = "system-file-manager";

            this.window_vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 5);

            this.progress_window.get_content_area ().set_border_width (10);
            this.progress_window.get_content_area ().add (this.window_vbox);
            this.window_vbox.show ();

            this.progress_window.delete_event.connect ((widget, event) => {
                widget.hide ();
                return true;
            });
        }

        progress_window.set_transient_for (application.get_active_window ());
    }

    private void progress_info_finished_cb (Marlin.Progress.Info info) {
        application.release ();

        if (active_infos > 0) {
            this.active_infos--;
            /* Only notify if application is not focussed. Add a delay
             * so that the active application window has time to refocus (if the application itself is focussed)
             * after progress window dialog is hidden. We have to wait until the dialog is hidden
             * because it steals focus from the application main window. This also means that a notification
             * is only sent after last operation finishes and the progress window closes. 
             * FIXME: Avoid use of a timeout by not using a dialog for progress window or otherwise.*/
            Timeout.add (100, () => {
                if (!application.get_active_window ().has_toplevel_focus) {
                    show_operation_complete_notification (info, active_infos < 1);
                }
                return false;
            });
        } else {
            warning ("Attempt to decrement zero active infos");
        }
        /* For rapid file transfers this can get called before progress window was been created */
        if (active_infos < 1 && progress_window != null && progress_window.visible) {
            (this.progress_window as Gtk.Window).hide ();
        }
#if HAVE_UNITY
        update_unity_launcher (info, false);
#endif
    }

    private void show_operation_complete_notification (Marlin.Progress.Info info, bool all_finished) {
        if (info.get_cancellable ().is_cancelled ()) {
            return; /* No notification of cancellation action required */
        }

        /* TRANSLATORS: %s will be replaced by the title of the file operation */
        var result = (_("Completed %s")).printf (info.get_title ());

        if (all_finished) {
            result = result + "\n" + _("All file operations have ended");
        }

        var complete_notification = new GLib.Notification (TITLE);
        complete_notification.set_body (result);
        complete_notification.set_icon (new GLib.ThemedIcon (Marlin.ICON_APP_LOGO));
        application.send_notification ("Pantheon Files Operation", complete_notification);
    }

#if HAVE_UNITY
    private void update_unity_launcher (Marlin.Progress.Info info,
                                        bool added) {

        if (this.quicklist_handler == null) {
            this.quicklist_handler = QuicklistHandler.get_singleton ();

            if (this.quicklist_handler == null)
                return;

            build_unity_quicklist ();
        }

        foreach (var marlin_lentry in this.quicklist_handler.launcher_entries)
            update_unity_launcher_entry (info, marlin_lentry);

        if (added)
            info.progress_changed.connect (unity_progress_changed);
    }

    private void build_unity_quicklist () {
        /* Create menu items for the quicklist */
        foreach (var marlin_lentry in this.quicklist_handler.launcher_entries) {
            /* Separator between bookmarks and progress items */
            var separator = new Dbusmenu.Menuitem ();

            separator.property_set (Dbusmenu.MENUITEM_PROP_TYPE,
                                    Dbusmenu.CLIENT_TYPES_SEPARATOR);
            separator.property_set (Dbusmenu.MENUITEM_PROP_LABEL,
                                    "Progress items separator");
            marlin_lentry.progress_quicklists.append (separator);

            /* "Show progress window" menu item */
            var show_menuitem = new Dbusmenu.Menuitem ();

            show_menuitem.property_set (Dbusmenu.MENUITEM_PROP_LABEL,
                                        _("Show Copy Dialog"));

            show_menuitem.item_activated.connect (() => {
                (this.progress_window as Gtk.Window).present ();
            });

            marlin_lentry.progress_quicklists.append (show_menuitem);

            /* "Cancel in-progress operations" menu item */
            var cancel_menuitem = new Dbusmenu.Menuitem ();

            cancel_menuitem.property_set (Dbusmenu.MENUITEM_PROP_LABEL,
                                          _("Cancel All In-progress Actions"));

            cancel_menuitem.item_activated.connect (() => {
                unowned List<Marlin.Progress.Info> infos = this.manager.get_all_infos ();

                foreach (var info in infos)
                    info.cancel ();
            });

            marlin_lentry.progress_quicklists.append (cancel_menuitem);
        }
    }

    private void update_unity_launcher_entry (Marlin.Progress.Info info,
                                              Marlin.LauncherEntry marlin_lentry) {
        Unity.LauncherEntry unity_lentry = marlin_lentry.entry;

        if (this.active_infos > 0) {
            unity_lentry.progress_visible = true;
            unity_progress_changed ();
            show_unity_quicklist (marlin_lentry, true);
        } else {
            unity_lentry.progress_visible = false;
            unity_lentry.progress = 0.0;
            show_unity_quicklist (marlin_lentry, false);

            Cancellable pc = info.get_cancellable ();

            if (!pc.is_cancelled ()) {
                unity_lentry.urgent = true;

                Timeout.add_seconds (2, () => {
                    unity_lentry.urgent = false;
                    return false;
                });
            }
        }
    }

    private void show_unity_quicklist (Marlin.LauncherEntry marlin_lentry,
                                       bool show) {

        Unity.LauncherEntry unity_lentry = marlin_lentry.entry;
        Dbusmenu.Menuitem quicklist = unity_lentry.quicklist;

        foreach (Dbusmenu.Menuitem menuitem in marlin_lentry.progress_quicklists) {
            if (show) {
                if (menuitem.get_parent () == null)
                    quicklist.child_add_position (menuitem, -1);
            } else {
                quicklist.child_delete (menuitem);
            }
        }
    }

    private void unity_progress_changed () {
        double progress = 0;
        double current = 0;
        double total = 0;
        unowned List<Marlin.Progress.Info> infos = this.manager.get_all_infos ();

        foreach (var _info in infos) {
            double c = _info.get_current ();
            double t = _info.get_total ();

            if (c < 0)
                c = 0;

            if (t <= 0)
                continue;

            current += c;
            total += t;
        }

        if (current >= 0 && total > 0)
            progress = current / total;

        if (progress > 1.0)
            progress = 1.0;

        foreach (Marlin.LauncherEntry marlin_lentry in this.quicklist_handler.launcher_entries) {
            Unity.LauncherEntry unity_lentry = marlin_lentry.entry;
            unity_lentry.progress = progress;
        }
    }
#endif

}
