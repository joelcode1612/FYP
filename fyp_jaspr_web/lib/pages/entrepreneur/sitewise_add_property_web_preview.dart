/// SiteWise — white workspace navbar + Add Property PRESENTATION PREVIEW.
///
/// This is a standalone visual implementation for fyp_jaspr_web (Jaspr).
/// It does NOT connect to FastAPI, Supabase, media storage, or Provider.
/// It does NOT modify the application's existing add-property route.
///
/// Use this component only as a design preview until the existing repository's
/// AddPropertyPage / form controller / repository methods are mapped to it.
/// When used inside an existing entrepreneur layout, pass showNavbar: false
/// so the shared header is not rendered twice.
/// CSS: sitewise_add_property_preview.css (loaded by the surrounding shell).

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

@client
class SitewiseAddPropertyDesignPreview extends StatefulComponent {
  const SitewiseAddPropertyDesignPreview({super.key, this.showNavbar = true});

  final bool showNavbar;

  @override
  State<SitewiseAddPropertyDesignPreview> createState() =>
      _SitewiseAddPropertyDesignPreviewState();
}

class _SitewiseAddPropertyDesignPreviewState
    extends State<SitewiseAddPropertyDesignPreview> {
  int _step = 1;
  // Presentation sample values matching the supplied SiteWise mockup.
  String _propertyName = 'SS15 Corner Retail';
  String _propertyType = 'Shoplot';
  String _monthlyRent = '7800';
  String _builtUpArea = '1680';
  String _address = '';
  String _state = 'Selangor';
  String _district = 'Petaling';
  String _postcode = '';
  String _latitude = '';
  String _longitude = '';
  String _notes = '';
  String? _validation;

  static const _stepNames = [
    'Property details', 'Location', 'Photos', 'Review', 'Confirmation',
  ];
  static const _stepSubtitles = [
    'Enter the basic details of your commercial unit.',
    'Specify the exact address and verify the map position.',
    'Prepare your property photo gallery.',
    'Check your details before sending them to your backend.',
    'See the confirmation layout without creating a record.',
  ];

  String _display(String text) => text.trim().isEmpty ? 'Not provided' : text;

  bool _validateCurrent() {
    if (_step == 1) {
      if (_propertyName.trim().isEmpty) {
        _validation = 'Enter a property name to continue.';
        return false;
      }
      final rent = double.tryParse(_monthlyRent.trim());
      if (rent == null || rent <= 0) {
        _validation = 'Enter a valid monthly rent greater than zero.';
        return false;
      }
      final area = double.tryParse(_builtUpArea.trim());
      if (area == null || area <= 0) {
        _validation = 'Enter a valid built-up area greater than zero.';
        return false;
      }
    }
    if (_step == 2) {
      if (_address.trim().isEmpty ||
          _state.trim().isEmpty ||
          _district.trim().isEmpty) {
        _validation = 'Address, state and district are required.';
        return false;
      }
      if (_latitude.trim().isNotEmpty || _longitude.trim().isNotEmpty) {
        final lat = double.tryParse(_latitude);
        final lon = double.tryParse(_longitude);
        if (lat == null || lon == null ||
            lat < -90 || lat > 90 || lon < -180 || lon > 180) {
          _validation = 'Enter valid latitude and longitude together.';
          return false;
        }
      }
    }
    _validation = null;
    return true;
  }

  void _goNext() {
    if (_step == 5) return;
    setState(() {
      if (_validateCurrent()) _step += 1;
    });
  }

  void _goBack() {
    if (_step <= 1) return;
    setState(() {
      _step -= 1;
      _validation = null;
    });
  }

  void _edit(int step) => setState(() {
    _step = step;
    _validation = null;
  });

  @override
  Component build(BuildContext context) => div(classes: 'swap', [
    a(href: '#swap-main', classes: 'swap-skip', [
      Component.text('Skip to Add Property form'),
    ]),
    if (component.showNavbar) const SitewiseWhiteWorkspaceNavbar(),
    div(id: 'swap-main', classes: 'swap-main', [
      div(classes: 'swap-breadcrumb', [
        a(href: '/entrepreneur', [Component.text('Home')]),
        span([Component.text('›')]),
        a(href: '/entrepreneur/my-properties', [Component.text('My Properties')]),
        span([Component.text('›')]),
        span([Component.text('Add Property')]),
      ]),
      div(classes: 'swap-heading-line', [
        div([
          p(classes: 'swap-kicker', [Component.text('Entrepreneur workspace')]),
          h1([Component.text('Add commercial property')]),
          p(classes: 'swap-intro', [
            Component.text(
              'Set up a property profile for location analysis. Complete each '
              'section, then review the information before submitting through '
              'your existing FastAPI workflow.',
            ),
          ]),
        ]),
        span(classes: 'swap-draft-pill', [Component.text('Presentation preview')]),
      ]),
      _stepper(),
      div(classes: 'swap-grid', [
        div(classes: 'swap-card', [
          if (_step < 5) ...[
            div(classes: 'swap-card-head', [
              h2([Component.text(_stepNames[_step - 1])]),
              p([Component.text(_stepSubtitles[_step - 1])]),
            ]),
            div(classes: 'swap-card-body', [
              if (_step == 1) _propertyDetails(),
              if (_step == 2) _location(),
              if (_step == 3) _photos(),
              if (_step == 4) _review(),
              if (_validation != null)
                p(
                  classes: 'swap-status',
                  attributes: {'role': 'alert'},
                  [Component.text(_validation!)],
                ),
            ]),
            div(classes: 'swap-card-foot', [
              if (_step > 1)
                button(
                  classes: 'swap-btn',
                  attributes: {'type': 'button'},
                  events: events(onClick: _goBack),
                  [Component.text('← Back')],
                )
              else
                span([Component.text('Step 1 of 5')]),
              button(
                classes: 'swap-btn swap-btn-primary',
                attributes: {'type': 'button'},
                events: events(onClick: _goNext),
                [
                  Component.text(
                    _step == 4 ? 'Preview confirmation →' : 'Continue →',
                  ),
                ],
              ),
            ]),
          ] else
            _confirmation(),
        ]),
        div(classes: 'swap-panel-right', [
          _summaryCard(),
          div(classes: 'swap-card swap-side-card swap-help', [
            h3([Component.text('Designed for SiteWise')]),
            p([
              Component.text(
                'This preview keeps your existing property routes, blue design '
                'tokens, form expectations and Clean Architecture boundaries. '
                'No API calls or database writes occur here.',
              ),
            ]),
          ]),
        ]),
      ]),
    ]),
  ]);

  Component _stepper() => div(
    classes: 'swap-stepper',
    attributes: {'aria-label': 'Add Property progress'},
    [
      for (var index = 0; index < _stepNames.length; index++)
        div(
          classes: 'swap-step${index + 1 == _step ? ' is-active' : ''}'
              '${index + 1 < _step ? ' is-done' : ''}',
          [
            span(classes: 'swap-step-index', [
              Component.text(index + 1 < _step ? '✓' : '${index + 1}'),
            ]),
            div(classes: 'swap-step-meta', [
              div(classes: 'swap-step-name', [
                Component.text(_stepNames[index]),
              ]),
              div(classes: 'swap-step-detail', [
                Component.text(index + 1 == _step ? 'In progress' :
                    index + 1 < _step ? 'Completed' : 'Upcoming'),
              ]),
            ]),
          ],
        ),
    ],
  );

  Component _field(
    String id,
    String labelText,
    String value,
    void Function(String) onChanged, {
    String placeholder = '',
    bool requiredField = false,
    bool full = false,
    bool numeric = false,
    String? hint,
  }) => div(classes: 'swap-field${full ? ' is-full' : ''}', [
    label(htmlFor: id, [
      Component.text(labelText),
      if (requiredField)
        span(classes: 'swap-required', [Component.text(' *')]),
    ]),
    input(
      type: numeric ? InputType.number : InputType.text,
      classes: 'swap-input',
      attributes: {
        'id': id,
        'name': id,
        'value': value,
        'placeholder': placeholder,
        if (numeric) 'min': '0',
        if (numeric) 'step': 'any',
        if (requiredField) 'required': '',
      },
      events: events<String>(onInput: (text) => setState(() {
        onChanged(text);
        _validation = null;
      })),
    ),
    if (hint != null)
      div(classes: 'swap-hint', [Component.text(hint)]),
  ]);

  Component _propertyDetails() => div([
    div(classes: 'swap-form-grid', [
      _field(
        'sw-name', 'Property name', _propertyName,
        (v) => _propertyName = v,
        full: true, requiredField: true,
        placeholder: 'e.g. SS15 Corner Retail',
      ),
      _field(
        'sw-rent', 'Monthly rental (MYR)', _monthlyRent,
        (v) => _monthlyRent = v,
        requiredField: true, numeric: true, placeholder: 'e.g. 7800',
      ),
      _field(
        'sw-area', 'Built-up area (sq ft)', _builtUpArea,
        (v) => _builtUpArea = v,
        requiredField: true, numeric: true, placeholder: 'e.g. 1680',
      ),
    ]),
    div(classes: 'swap-divider', []),
    div(classes: 'swap-field', [
      span(classes: 'swap-field-legend', [Component.text('Property type *')]),
      div(classes: 'swap-choice-grid', [
        for (final type in const ['Shoplot', 'Retail space', 'Office', 'Industrial', 'Other'])
          button(
            classes: 'swap-choice',
            attributes: {
              'type': 'button',
              'aria-pressed': '${_propertyType == type}',
            },
            events: events(onClick: () => setState(() {
              _propertyType = type;
              _validation = null;
            })),
            [Component.text(type)],
          ),
      ]),
      div(classes: 'swap-hint', [
        Component.text('Select the category used in your existing property listings.'),
      ]),
    ]),
    _notice('Rental and floor area are validated in the UI preview only. The backend must validate them again.'),
  ]);

  Component _location() => div([
    div(classes: 'swap-form-grid', [
      _field('sw-address', 'Street address', _address,
          (v) => _address = v,
          full:true, requiredField:true,
          placeholder:'Street, building and unit number'),
      _field('sw-state', 'State', _state, (v) => _state = v,
          requiredField:true,placeholder:'e.g. Selangor'),
      _field('sw-district', 'District', _district,
          (v) => _district = v,
          requiredField:true, placeholder:'e.g. Petaling'),
      _field('sw-postcode', 'Postcode', _postcode,
          (v) => _postcode = v, placeholder:'e.g. 47500'),
      div([]),
      _field('sw-lat', 'Latitude (optional)', _latitude,
          (v) => _latitude = v, numeric:true, placeholder:'e.g. 3.0750'),
      _field('sw-long', 'Longitude (optional)', _longitude,
          (v) => _longitude = v, numeric:true, placeholder:'e.g. 101.5900'),
    ]),
    div(classes:'swap-map',attributes:{
      'role':'img',
      'aria-label':'Illustrative map pattern. Live geocoding uses your existing map integration.',
    }, [
      div(classes:'swap-map-caption', [
        Component.text('Map illustration only — connect the existing geocoding/map component here.'),
      ]),
    ]),
  ]);

  Component _photos() => div([
    div(classes:'swap-upload', [
      div(classes:'swap-upload-symbol',[Component.text('▣')]),
      h3([Component.text('Property photo gallery')]),
      p([Component.text(
        'Drag/drop and upload should use the existing SiteWise image-storage '
        'component. This visual preview does not read or upload local files.'
      )]),
      span(classes:'swap-draft-pill',[Component.text('Optional step')]),
    ]),
    div(classes:'swap-photo-row', [
      for (final title in const ['Exterior photo', 'Interior photo', 'Floor layout'])
        div(classes:'swap-photo',[ 
          span(classes:'swap-photo-symbol',[Component.text('▧')]),
          span([Component.text(title)]),
        ]),
    ]),
    _notice('Supported file types, maximum size and image uploads must be enforced by the existing media backend.'),
  ]);

  Component _review() => div([
    _reviewSection('Property details', 1, [
      _pair('Property name', _display(_propertyName)),
      _pair('Property type', _propertyType),
      _pair('Monthly rent', _monthlyRent.isEmpty ? '—' : 'RM $_monthlyRent'),
      _pair('Built-up area', _builtUpArea.isEmpty ? '—' : '$_builtUpArea sq ft'),
    ]),
    _reviewSection('Location & address', 2, [
      _pair('Address', _display(_address)),
      _pair('State', _display(_state)),
      _pair('District', _display(_district)),
      _pair('Postcode', _display(_postcode)),
      _pair('Coordinates', _latitude.isEmpty ? 'Not provided' :
          '$_latitude, $_longitude'),
    ]),
    _reviewSection('Photos', 3, [
      _pair('Upload status', 'Not connected in this presentation preview'),
    ]),
    _notice('Preview confirmation does not send an API request or create a property. Wire your existing use case after review.'),
  ]);

  Component _reviewSection(String heading, int target, List<Component> entries) =>
      div(classes:'swap-review-section', [
        div(classes:'swap-review-head', [
          h3([Component.text(heading)]),
          button(
            classes:'swap-edit',
            attributes:{'type':'button'},
            events: events(onClick: () => _edit(target)),
            [Component.text('Edit')],
          ),
        ]),
        div(classes:'swap-review-grid',entries),
      ]);

  Component _pair(String title, String value) => div([
    span(classes:'swap-review-label',[Component.text(title)]),
    span(classes:'swap-review-value',[Component.text(value)]),
  ]);

  Component _confirmation() => div(classes:'swap-confirm', [
    span(classes:'swap-demo-tag',[Component.text('UI preview — not saved')]),
    div(classes:'swap-confirm-badge',[Component.text('✓')]),
    h2([Component.text('Submission confirmation design')]),
    p([Component.text(
      'This is how a successful response could look after your existing '
      'FastAPI Add Property use case returns a verified property ID.'
    )]),
    div(classes:'swap-success-box', [
      _pair('Sample property', _display(_propertyName)),
      div(classes:'swap-divider',[]),
      _pair('Property ID', 'Assigned by backend after successful creation'),
    ]),
    button(
      classes:'swap-btn swap-btn-primary',
      attributes:{'type':'button'},
      events: events(onClick: () => _edit(1)),
      [Component.text('Review the design again')],
    ),
    a(href:'/entrepreneur/my-properties',classes:'swap-btn', [
      Component.text('Go to My Properties'),
    ]),
  ]);

  Component _summaryCard() => div(classes:'swap-card swap-side-card',[ 
    div(classes:'swap-side-kicker',[Component.text('Property snapshot')]),
    h3([Component.text('Your draft at a glance')]),
    p([Component.text('A live summary of the values entered into this preview form.')]),
    Component.element(tag:'dl',classes:'swap-information-list',children:[
      _info('Property name', _display(_propertyName)),
      _info('Type', _propertyType),
      _info('Monthly rent', _monthlyRent.isEmpty ? 'Not entered' : 'RM $_monthlyRent'),
      _info('Floor area', _builtUpArea.isEmpty ? 'Not entered' : '$_builtUpArea sq ft'),
      _info('State', _display(_state)),
      _info('District', _display(_district)),
      _info('Photos', 'Not connected'),
    ]),
  ]);

  Component _info(String title, String value) => div(classes:'swap-info-line', [
    Component.element(tag:'dt',children:[Component.text(title)]),
    Component.element(tag:'dd',children:[Component.text(value)]),
  ]);

  Component _notice(String message) => div(classes:'swap-notice', [
    span(classes:'swap-notice-icon',[Component.text('ⓘ')]),
    span([Component.text(message)]),
  ]);
}

/// Navbar can also be reused inside the existing entrepreneur shell.
/// Do NOT render it alongside the existing shared navbar: replace that single
/// shared header manually after reviewing the repository's layout component.
class SitewiseWhiteWorkspaceNavbar extends StatelessComponent {
  const SitewiseWhiteWorkspaceNavbar({
    super.key,
    this.activePath = '/entrepreneur',
  });

  final String activePath;

  @override
  Component build(BuildContext context) => div(classes: 'swap swap-navbar-only', [
    _navbarInner(),
  ]);

  Component _navbarInner() => div(classes: 'swap-header-wrap', [
    div(classes: 'swap-nav-shell', [
      a(href: '/entrepreneur', classes: 'swap-brand', [
        span(classes: 'swap-brand-mark', [Component.text('◈')]),
        div([
          div(classes: 'swap-brand-title', [Component.text('Sitewise')]),
          div(classes: 'swap-brand-sub', [
            Component.text('ENTREPRENEUR WORKSPACE'),
          ]),
        ]),
      ]),
      nav(classes: 'swap-links', attributes: {'aria-label': 'Workspace'}, [
        _navLink('Home', '/entrepreneur'),
        _navLink('Explore', '/entrepreneur/explore'),
        _navLink('Map', '/entrepreneur/map'),
        _navLink('Recommendations', '/entrepreneur/recommendations'),
        _navLink('Compare', '/entrepreneur/compare'),
        _navLink('Saved', '/entrepreneur/saved'),
        _navLink('Profile', '/entrepreneur/profile'),
      ]),
      div(classes: 'swap-actions', [
        span(
          classes: 'swap-nav-icon',
          attributes: {'aria-hidden': 'true', 'title': 'Search'},
          [_navIconSvg(true)],
        ),
        span(
          classes: 'swap-nav-icon',
          attributes: {'aria-hidden': 'true', 'title': 'Notifications'},
          [_navIconSvg(false)],
        ),
        a(href: '/entrepreneur/profile', classes: 'swap-avatar', [
          span(classes: 'swap-avatar-circle', [Component.text('SW')]),
          span(classes: 'swap-avatar-caret', [Component.text('⌄')]),
        ]),
        Component.element(
          tag: 'details',
          classes: 'swap-mobile-menu',
          children: [
            Component.element(
              tag: 'summary',
              attributes: {'aria-label': 'Open workspace navigation'},
              children: [Component.text('☰')],
            ),
            nav(classes: 'swap-mobile-items',
                attributes: {'aria-label': 'Mobile workspace'}, [
              _navLink('Home', '/entrepreneur'),
              _navLink('Explore', '/entrepreneur/explore'),
              _navLink('Map', '/entrepreneur/map'),
              _navLink('Recommendations', '/entrepreneur/recommendations'),
              _navLink('Compare', '/entrepreneur/compare'),
              _navLink('Saved', '/entrepreneur/saved'),
              _navLink('Profile', '/entrepreneur/profile'),
              _navLink('My Properties', '/entrepreneur/my-properties'),
            ]),
          ],
        ),
      ]),
    ]),
  ]);


  Component _navIconSvg(bool search) => Component.element(
    tag: 'svg',
    attributes: {
      'viewBox': '0 0 24 24',
      'width': '18',
      'height': '18',
      'fill': 'none',
      'stroke': 'currentColor',
      'stroke-width': '1.8',
      'stroke-linecap': 'round',
      'stroke-linejoin': 'round',
      'aria-hidden': 'true',
    },
    children: search
        ? [
            Component.element(tag: 'circle', attributes: {
              'cx': '10.8', 'cy': '10.8', 'r': '6.5',
            }, children: []),
            Component.element(tag: 'path', attributes: {
              'd': 'm16 16 4.5 4.5',
            }, children: []),
          ]
        : [
            Component.element(tag: 'path', attributes: {
              'd': 'M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9Z',
            }, children: []),
            Component.element(tag: 'path', attributes: {
              'd': 'M10 21h4',
            }, children: []),
          ],
  );

  Component _navLink(String title, String href) => a(
    href: href,
    classes: 'swap-link',
    attributes: href == activePath ? {'aria-current':'page'} : {},
    [Component.text(title)],
  );

}
