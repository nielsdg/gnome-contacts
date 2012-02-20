/* -*- Mode: vala; indent-tabs-mode: t; c-basic-offset: 2; tab-width: 8 -*- */
/*
 * Copyright (C) 2011 Alexander Larsson <alexl@redhat.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

using Gtk;
using Gee;

/* Requriements:
   + sort
   + filter
   + first char or type custom "separators"
     (create, destroy, update)
   + Work with largish sets of children
   + selection and keynave

   filter => child visibility setting

   Q:
   How to construct separators?
   What about resort a single item, can be problem if more change
    at the same time, need a stable sort...

   settings:
	  sort function
	  filter function
	  needs_separator function
	  create_separator
	  update_separator (if the child below it changes)

	ops:
	  child-changed (resort, refilter,
	  resort-all
	  refilter-all

	Impl:
	 GSequence for children
	 GHashTable for child to iter mapping
*/

public class Contacts.Sorted : Container {
  public delegate bool FilterFunc (Widget child);
  public delegate bool NeedSeparatorFunc (Widget widget, Widget? before);
  public delegate Widget CreateSeparatorFunc ();
  public delegate void UpdateSeparatorFunc (Widget separator, Widget child, Widget? before);

  struct ChildInfo {
    Widget widget;
    Widget? separator;
    SequenceIter<ChildInfo?> iter;
    int y;
    int height;
  }

  Sequence<ChildInfo?> children;
  HashMap<unowned Widget, unowned ChildInfo?> child_hash;
  CompareDataFunc<Widget>? sort_func;
  FilterFunc? filter_func;
  NeedSeparatorFunc? need_separator_func;
  CreateSeparatorFunc? create_separator_func;
  UpdateSeparatorFunc? update_separator_func;
  protected Gdk.Window event_window;
  unowned ChildInfo? selected_child;

  private int do_sort (ChildInfo? a, ChildInfo? b) {
    return sort_func (a.widget, b.widget);
  }

  public Sorted () {
    set_has_window (false);
    set_redraw_on_allocate (false);

    children = new Sequence<ChildInfo?>();
    child_hash = new HashMap<unowned Widget, unowned ChildInfo?> ();
  }

  public override bool button_press_event (Gdk.EventButton event) {
    if (event.button == 1) {
      var y = event.y;
      unowned ChildInfo? child_info = null;
      for (var iter = children.get_begin_iter (); !iter.is_end (); iter = iter.next ()) {
	unowned ChildInfo? info = iter.get ();
	if (y >= info.y && y < info.y + info.height) {
	  child_info = info;
	  break;
	}
      }
      selected_child = child_info;

      child_selected (selected_child != null ? selected_child.widget : null);
      queue_draw ();
    }
    return false;
  }

  public virtual signal void child_selected (Widget? child) {
  }

  public override bool draw (Cairo.Context cr) {
    Allocation allocation;
    this.get_allocation (out allocation);

    var context = this.get_style_context ();

    context.save ();
    Gtk.render_background (context, cr,
			   0, 0, allocation.width, allocation.height);

    if (selected_child != null) {
      context.set_state (StateFlags.SELECTED);
      Gtk.render_background (context, cr,
			     0, selected_child.y,
			     allocation.width, selected_child.height);
    }

    context.restore ();

    base.draw (cr);

    return true;
  }

  public override void realize () {
    Allocation allocation;
    get_allocation (out allocation);
    set_realized (true);

    Gdk.WindowAttr attributes = { };
    attributes.x = allocation.x;
    attributes.y = allocation.y;
    attributes.width = allocation.width;
    attributes.height = allocation.height;
    attributes.window_type = Gdk.WindowType.CHILD;
    attributes.event_mask = this.get_events () | Gdk.EventMask.EXPOSURE_MASK | Gdk.EventMask.BUTTON_PRESS_MASK;

    var window = get_parent_window ();
    this.set_window (window);

    attributes.wclass = Gdk.WindowWindowClass.INPUT_ONLY;
    event_window = new Gdk.Window (window, attributes,
				   Gdk.WindowAttributesType.X |
				   Gdk.WindowAttributesType.Y);
    event_window.set_user_data (this);
  }

  public override void unrealize () {
    event_window.set_user_data (null);
    event_window.destroy ();
    event_window = null;
    base.unrealize ();
  }

  private void apply_filter (Widget child) {
    bool do_show = true;
    if (filter_func != null)
      do_show = filter_func (child);
    child.set_child_visible (do_show);
  }

  private void apply_filter_all () {
    for (var iter = children.get_begin_iter (); !iter.is_end (); iter = iter.next ()) {
      unowned ChildInfo? child_info = iter.get ();
      apply_filter (child_info.widget);
    }
  }

  public void set_filter_func (owned FilterFunc? f) {
    filter_func = (owned)f;
    refilter ();
  }

  public void set_separator_funcs (owned NeedSeparatorFunc? need_separator,
				   owned CreateSeparatorFunc? create_separator,
				   owned UpdateSeparatorFunc? update_separator = null) {
    need_separator_func = (owned)need_separator;
    create_separator_func = (owned)create_separator;
    update_separator_func = (owned)update_separator;
    reseparate ();
  }

  public void refilter () {
    apply_filter_all ();
    reseparate ();
    queue_resize ();
  }

  public void resort () {
    children.sort (do_sort);
    reseparate ();
    queue_resize ();
  }

  private SequenceIter<ChildInfo?>? get_previous_visible (SequenceIter<ChildInfo?> _iter) {
    if (_iter.is_begin())
      return null;
    var iter = _iter;

    do {
      iter = iter.prev ();

      unowned ChildInfo? child_info = iter.get ();
      unowned Widget widget = child_info.widget;
      if (widget.get_visible () && widget.get_child_visible ())
	return iter;
    } while (!iter.is_begin ());

    return null;
  }

  private SequenceIter<ChildInfo?>? get_next_visible (SequenceIter<ChildInfo?> _iter) {
    if (_iter.is_end())
      return _iter;

    var iter = _iter;
    do {
      iter = iter.next ();

      if (!iter.is_end ()) {
	unowned ChildInfo? child_info = iter.get ();
	unowned Widget widget = child_info.widget;
	if (widget.get_visible () && widget.get_child_visible ())
	  return iter;
      }
    } while (!iter.is_end ());

    return iter;
  }

  private void update_separator (SequenceIter<ChildInfo?> iter, bool update_if_exist) {
    if (iter.is_end ())
      return;

    unowned ChildInfo? info = iter.get ();
    var before_iter = get_previous_visible (iter);
    var widget = info.widget;
    Widget? before_widget = null;
    if (before_iter != null) {
      unowned ChildInfo? before_info = before_iter.get ();
      before_widget = before_info.widget;
    }

    bool need_separator = false;

    if (need_separator_func != null &&
	widget.get_visible () &&
	widget.get_child_visible ())
      need_separator = need_separator_func (widget, before_widget);

    if (need_separator) {
      if (info.separator == null) {
	info.separator = create_separator_func ();
	info.separator.set_parent (this);
	info.separator.show ();
	if (update_separator_func != null)
	  update_separator_func (info.separator, widget, before_widget);
	this.queue_resize ();
      } else if (update_if_exist) {
	if (update_separator_func != null)
	  update_separator_func (info.separator, widget, before_widget);
      }
    } else {
      if (info.separator != null) {
	info.separator.unparent ();
	info.separator = null;
	this.queue_resize ();
      }
    }
  }

  public void reseparate () {
    for (var iter = children.get_begin_iter (); !iter.is_end (); iter = iter.next ()) {
      update_separator (iter, false);
    }
    queue_resize ();
  }

  public void set_sort_func (owned CompareDataFunc<Widget>? f) {
    sort_func = (owned)f;
    resort ();
  }

  public override void map () {
    event_window.show ();
    base.map ();
  }

  public override void unmap () {
    event_window.hide ();
    base.unmap ();
  }

  private unowned ChildInfo? lookup_info (Widget widget) {
    return child_hash.get (widget);
  }

  public override void add (Widget widget) {
    ChildInfo? the_info = { widget };
    unowned ChildInfo? info = the_info;
    SequenceIter<ChildInfo?> iter;

    child_hash.set (widget, info);

    if (sort_func != null)
      iter = children.insert_sorted ((owned) the_info, do_sort);
    else
      iter = children.append ((owned) the_info);

    apply_filter (widget);

    var prev_next = get_next_visible (iter);
    update_separator (iter, true);
    update_separator (get_next_visible (iter), true);
    update_separator (prev_next, true);

    info.iter = iter;

    widget.set_parent (this);
  }

  public void child_changed (Widget widget) {
    unowned ChildInfo? info = lookup_info (widget);
    if (info == null)
      return;

    var prev_next = get_previous_visible (info.iter);

    if (sort_func != null) {
      children.sort_changed (info.iter, do_sort);
      this.queue_resize ();
    }
    apply_filter (info.widget);
    update_separator (info.iter, true);
    update_separator (get_next_visible (info.iter), true);
    update_separator (prev_next, true);

  }

  public override void remove (Widget widget) {
    unowned ChildInfo? info = lookup_info (widget);
    if (info == null)
      return;

    var next = get_next_visible (info.iter);

    bool was_visible = widget.get_visible ();
    widget.unparent ();

    child_hash.unset (widget);

    update_separator (next, false);

    if (was_visible && this.get_visible ())
      this.queue_resize ();
  }

  public override void forall_internal (bool include_internals,
					Gtk.Callback callback) {
    for (var iter = children.get_begin_iter (); !iter.is_end (); iter = iter.next ()) {
      unowned ChildInfo? child_info = iter.get ();
      if (child_info.separator != null && include_internals)
	callback (child_info.separator);
      callback (child_info.widget);
    }
  }

  public override void compute_expand_internal (out bool hexpand, out bool vexpand) {
    base.compute_expand_internal (out hexpand, out vexpand);
    /* We don't expand vertically beyound the minimum size */
    vexpand = false;
  }

  public override Type child_type () {
    return typeof (Widget);
  }

  public override Gtk.SizeRequestMode get_request_mode () {
    return SizeRequestMode.HEIGHT_FOR_WIDTH;
  }

  public override void get_preferred_height (out int minimum_height, out int natural_height) {
    int natural_width;
    get_preferred_width (null, out natural_width);
    get_preferred_height_for_width_internal (natural_width, out minimum_height, out natural_height);
  }

  public override void get_preferred_height_for_width (int width, out int minimum_height, out int natural_height) {
    minimum_height = 0;
    for (var iter = children.get_begin_iter (); !iter.is_end (); iter = iter.next ()) {
      unowned ChildInfo? child_info = iter.get ();
      unowned Widget widget = child_info.widget;
      int child_min;

      if (!widget.get_visible () || !widget.get_child_visible ())
	continue;

      if (child_info.separator != null) {
	child_info.separator.get_preferred_height_for_width (width, out child_min, null);
	minimum_height += child_min;
      }

      widget.get_preferred_height_for_width (width, out child_min, null);
      minimum_height += child_min;
    }
    /* We always allocate the minimum height, since handling
       expanding rows is way too costly, and unlikely to
       be used, as lists are generally put inside a scrolling window
       anyway.
    */
    natural_height = minimum_height;
  }

  public override void get_preferred_width (out int minimum_width, out int natural_width) {
    minimum_width = 0;
    natural_width = 0;
    for (var iter = children.get_begin_iter (); !iter.is_end (); iter = iter.next ()) {
      unowned ChildInfo? child_info = iter.get ();
      unowned Widget widget = child_info.widget;
      int child_min, child_nat;

      if (!widget.get_visible () || !widget.get_child_visible ())
	continue;

      widget.get_preferred_width (out child_min, out child_nat);
      minimum_width = int.max (minimum_width, child_min);
      natural_width = int.max (natural_width, child_nat);

      if (child_info.separator != null) {
	child_info.separator.get_preferred_width (out child_min, out child_nat);
	minimum_width = int.max (minimum_width, child_min);
	natural_width = int.max (natural_width, child_nat);
      }
    }
  }

  public override void get_preferred_width_for_height (int height, out int minimum_width, out int natural_width) {
    get_preferred_width (out minimum_width, out natural_width);
  }

  public override void size_allocate (Gtk.Allocation allocation) {
    Allocation child_allocation = { 0, 0, 0, 0};

    set_allocation (allocation);

    if (event_window != null)
      event_window.move_resize (allocation.x,
				allocation.y,
				allocation.width,
				allocation.height);

    child_allocation.x = allocation.x;
    child_allocation.y = allocation.y;
    child_allocation.width = allocation.width;

    for (var iter = children.get_begin_iter (); !iter.is_end (); iter = iter.next ()) {
      unowned ChildInfo? child_info = iter.get ();
      unowned Widget widget = child_info.widget;
      int child_min;

      if (!widget.get_visible () || !widget.get_child_visible ()) {
	child_info.y = child_allocation.y;
	child_info.height = 0;
	continue;
      }

      if (child_info.separator != null) {
	child_info.separator.get_preferred_height_for_width (allocation.width, out child_min, null);
	child_allocation.height = child_min;

	child_info.separator.size_allocate (child_allocation);

	child_allocation.y += child_min;
      }

      widget.get_preferred_height_for_width (allocation.width, out child_min, null);
      child_allocation.height = child_min;

      child_info.y = child_allocation.y;
      child_info.height = child_allocation.height;
      widget.size_allocate (child_allocation);

      child_allocation.y += child_min;
    }
  }
}
