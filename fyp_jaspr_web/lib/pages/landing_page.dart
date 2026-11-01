import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/letter_reveal.dart';
import '../components/site_topbar.dart';
import '../components/ui.dart';

/// Public pre-auth landing page — the Jaspr port of
/// `sitewise-roles/index.html`.
///
/// This is a faithful structural + visual port of that source file: the fixed
/// top bar, the hero "scene" (the live Three.js model, mounted by
/// `web/three_scene.js` into `#concept3dScene` with a graceful CSS fallback),
/// the four numbered sections (problem/solution,
/// neighbourhood exploration, business assessment, recommendations/report) and
/// the footer. The interactive behaviour — challenge-pill switching, benefit-card
/// highlighting, the assessment sandbox (step tabs + live rent/revenue gauge)
/// and the recommendation showcase tabs — are implemented here as real Jaspr
/// client state, hydrated through the `app` client, so they work without the
/// source's `app.js`.
///
/// The 3D hero is the original Three.js composition, loaded from
/// `web/vendor/three.min.js` + `web/three_scene.js`; when WebGL is unavailable
/// the scene script reveals the `.model-fallback` composition instead, so the
/// page stays fully usable without JavaScript. Map pins, the 360° tour and the
/// gauge are illustrative (the dataset is sample EP-01037 etc.), exactly as in
/// the source.
///
/// Deliberately *not* `@client`: `SitewiseApp` is the client entry point for
/// every route, and Jaspr asserts that no client anchor nests inside another
/// one (`component_anchors.dart`), which would break hydration of the page.
class LandingPage extends StatefulComponent {
  const LandingPage({super.key});

  @override
  State<LandingPage> createState() => _LandingState();
}

class _LandingState extends State<LandingPage> {
  // Section 01 — problem/solution topic (0..3).
  int _challenge = 0;

  // Section 02 — active benefit card (1..3) + toggled map layers.
  int _benefit = 1;
  final Set<String> _layers = {'food', 'population', 'transit', 'amenities'};

  // Section 03 — assessment step (1..4), concept + live affordability.
  int _assessStep = 1;
  int _concept = 0;
  int _rent = 10000;
  int _revenue = 90000;
  final Set<String> _reqs = {
    '3-Phase Power Supply',
    'Kitchen Exhaust Readiness',
    'Commercial Grease Trap',
    'Ground Floor / Corner Visibility',
    'Customer Parking Access',
  };
  int _floorArea = 2200;

  // Section 04 — recommendation showcase tab (1..4) + selected candidate.
  int _recTab = 1;
  int _recProp = 0;
  int _hotspot = 1;

  // ----------------------------------------------------------------- data

  static const List<String> _challengeTitles = [
    'Important information is scattered.',
    'Rent can break the business plan.',
    'Competitors and catchment are invisible.',
    'Missing details hide real risk.',
  ];
  static const List<String> _challengeDesc = [
    'Property listings show the unit, but entrepreneurs may still need to '
        'investigate nearby competitors, local amenities, customer catchment, '
        'affordability and missing details across disconnected tabs.',
    'A rent that looks affordable on paper can consume the whole margin once '
        'sales assumptions are tested against a deterministic affordability rule.',
    'Without a neighbourhood view, entrepreneurs cannot see how many similar '
        'F&B venues, how much footfall and what access already exists nearby.',
    'Technical and regulatory blanks — extraction, licensing, grease capacity — '
        'are easy to miss until a site visit, when they may be deal-breakers.',
  ];
  static const List<String> _challengeBullets = [
    'Listing portals only show photos and asking rental price',
    'Manual spreadsheet guesswork for rent-to-revenue sustainability',
    'Unflagged missing technical or regulatory details',
  ];
  static const List<String> _solutionDesc = [
    'Sitewise combines property exploration, location insights, business '
        'requirements and explainable recommendations to help entrepreneurs '
        'compare options before a site visit.',
    'A deterministic rent affordability check tests the rent against concept '
        'benchmarks, so the plan is reviewed before any commitment.',
    'Explicit UNKNOWN flags surface specs that require on-site verification '
        'rather than letting them hide in the listing.',
    'Structured property details and explicit UNKNOWN flags expose the '
        'technical and regulatory gaps that would otherwise only surface at a '
        'site visit.',
  ];
  static const List<String> _solutionBullets = [
    'Multi-layer neighbourhood map with F&B & catchment pins',
    'Deterministic rent affordability check against concept benchmarks',
    'Explicit UNKNOWN flags for specs requiring on-site verification',
  ];

  static const List<Map<String, Object>> _concepts = [
    {
      'name': 'Specialty Café',
      'emoji': '☕',
      'bench': 12,
      'small': 'Target rent ≤ 12% of sales · High visibility & patio fit',
    },
    {
      'name': 'Quick-Service Restaurant',
      'emoji': '🥡',
      'bench': 14,
      'small': 'Target rent ≤ 14% of sales · High footfall & takeaway',
    },
    {
      'name': 'Cloud Kitchen',
      'emoji': '🛵',
      'bench': 8,
      'small': 'Target rent ≤ 8% of sales · Delivery hub & heavy MEP',
    },
    {
      'name': 'Bakery & Dessert',
      'emoji': '🥐',
      'bench': 12,
      'small': 'Target rent ≤ 12% of sales · 3-phase oven power fit',
    },
  ];

  static const List<String> _reqOptions = [
    '3-Phase Power Supply',
    'Kitchen Exhaust Readiness',
    'Commercial Grease Trap',
    'Ground Floor / Corner Visibility',
    'Customer Parking Access',
    'Outdoor Alfresco Patio',
  ];

  static const List<Map<String, String>> _candidates = [
    {
      'rank': 'RANK #01 · EP-01037',
      'fit': '88% Fit',
      'name': 'Shah Alam Seksyen 13 Corner',
      'meta': 'RM 10,000/mo · 2,400 sqft · Corner lot with patio apron',
      't1': '✓ Rent ON_TRACK',
      't2': '✓ 42.8k Catchment',
      't3': '⚠ Regulatory UNKNOWN',
    },
    {
      'rank': 'RANK #02 · EP-02084',
      'fit': '82% Fit',
      'name': 'SS15 Subang Jaya Shoplot',
      'meta': 'RM 14,500/mo · 1,850 sqft · Ex-F&B fitted unit',
      't1': '✓ Exhaust Ready',
      't2': 'High Competitor Density',
      't3': '',
    },
    {
      'rank': 'RANK #03 · EP-03119',
      'fit': '74% Fit',
      'name': 'Bukit Bintang Ground Retail',
      'meta': 'RM 22,000/mo · 2,100 sqft · High pedestrian flow',
      't1': '✓ 118k Daily Footfall',
      't2': 'Rent Above Threshold',
      't3': '',
    },
  ];

  static const List<Map<String, String>> _weights = [
    {'label': 'Affordability Fit', 'pct': '89%'},
    {'label': 'Catchment & Footfall', 'pct': '91%'},
    {'label': 'Competitor Balance', 'pct': '84%'},
    {'label': 'Technical Readiness', 'pct': '78%'},
  ];

  static const List<Map<String, String>> _hotspots = [
    {'id': 'frontage', 'title': 'Frontage Visibility'},
    {'id': 'exhaust', 'title': 'Exhaust & Kitchen Duct'},
    {'id': 'floor', 'title': 'Dining Floor Span'},
    {'id': 'patio', 'title': 'Alfresco Patio'},
  ];

  // -------------------------------------------------------------- computed

  double get _ratio => _revenue > 0 ? (_rent / _revenue) * 100 : 0.0;
  int get _bench => (_concepts[_concept]['bench'] as int);
  bool get _onTrack => _ratio <= _bench;
  int get _fill => (_ratio / 20 * 100).clamp(0, 100).round();

  // ================================================================ build

  @override
  Component build(BuildContext context) => div(classes: 'lnd', [
    const SiteTopbar(),
    _hero(),
    _problem(),
    _explore(),
    _assessment(),
    _recommendations(),
    _footer(),
  ]);

  // --------------------------------------------------------- letter reveal

  /// Hero headline is split into two runs so the `<em>` keeps its colour; the
  /// single [LetterRevealHeading] keeps the character stagger continuous across
  /// the boundary.
  static const String _heroLead = 'Find the right place for your ';
  static const String _heroEm = 'next F&B business.';

  // -------------------------------------------------------------- hero

  Component _hero() => section(
    classes: 'scroll-experience',
    attributes: {'aria-label': 'Commercial F&B property showcase'},
    [
      div(classes: 'scene-sticky', [
        div(classes: 'scene-mount', [
          div(
            id: 'concept3dScene',
            attributes: {
              'aria-label':
                  'Interactive illustrative 3D commercial F&B property model',
            },
            [],
          ),
          Component.element(
            tag: 'img',
            id: 'heroImage',
            classes: 'fallback-image hidden',
            attributes: {
              'alt': 'Illustrative commercial F&B property diorama',
              'src':
                  'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
            },
            children: [],
          ),
          div(
            classes: 'model-fallback',
            attributes: {'hidden': ''},
            [
              Component.text(
                '3D preview unavailable on this device. Use the interactive sections below.',
              ),
            ],
          ),
          div(classes: 'scene-glow', []),
        ]),
        div(classes: 'scene-ui', [
          div(
            classes: 'model-badge parallax-target',
            attributes: {'data-parallax-depth': '0.45'},
            [
              i([]),
              span([Component.text('Interactive 3D · Illustrative model')]),
            ],
          ),
          div(
            classes: 'scene-copy parallax-target',
            attributes: {'data-parallax-depth': '0.65'},
            [
              span(classes: 'scene-eyebrow', [
                i([]),
                span([
                  Component.text('Sitewise · Commercial F&B intelligence'),
                ]),
              ]),
              p(classes: 'scene-subtitle', [
                Component.text('A clearer way to choose'),
              ]),
              // Hero headline: two runs so the `<em>` keeps its colour, one
              // continuous stagger across the boundary.
              const LetterRevealHeading(
                level: 1,
                runs: [
                  LetterRun(_heroLead),
                  LetterRun(_heroEm, tag: 'em'),
                ],
              ),
              p([
                Component.text(
                  'Explore a commercial property in context — from its '
                  'surroundings and access to the evidence behind a '
                  'location recommendation.',
                ),
              ]),
              div(classes: 'scene-actions', [
                a(classes: 'btn primary', href: '#explore', [
                  Component.text('Explore properties ↓'),
                ]),
                a(classes: 'btn', href: '#assessment', [
                  Component.text('See how it works'),
                ]),
              ]),
            ],
          ),
          div(classes: 'glass-stack', [
            _glassCard(
              'Location context',
              'Focus ↗',
              'Shah Alam, Selangor',
              'Illustrative area label · no verified coordinates',
              _benefit == 1,
              focus: 'patio',
              parallaxDepth: '0.46',
            ),
            _glassCard(
              'Monthly rental',
              'Focus ↗',
              'RM 10,000',
              'Sample property · EP-01037',
              _benefit == 2,
              focus: 'frontage',
              parallaxDepth: '0.72',
            ),
            _glassCard(
              'F&B regulatory status',
              'Focus ↗',
              'UNKNOWN',
              'Verification required before a decision',
              _benefit == 3,
              danger: true,
              focus: 'rooftop',
              parallaxDepth: '0.56',
            ),
          ]),
          div(
            classes: 'camera-presets',
            attributes: {'role': 'group', 'aria-label': 'Camera angle presets'},
            [
              span([Component.text('View')]),
              _camPreset('Overview', 'overview', true),
              _camPreset('Frontage', 'frontage', false),
              _camPreset('Patio', 'patio', false),
              _camPreset('Rooftop', 'rooftop', false),
            ],
          ),
          div(
            id: 'modelControls',
            classes: 'scene-controls',
            attributes: {'role': 'toolbar', 'aria-label': '3D model controls'},
            [
              span([Component.text('3D')]),
              button(
                classes: 'scene-ctl',
                attributes: {
                  'data-model-action': 'zoom-in',
                  'title': 'Zoom in',
                  'aria-label': 'Zoom in',
                },
                [Component.text('+')],
              ),
              button(
                classes: 'scene-ctl',
                attributes: {
                  'data-model-action': 'zoom-out',
                  'title': 'Zoom out',
                  'aria-label': 'Zoom out',
                },
                [Component.text('−')],
              ),
              button(
                classes: 'scene-ctl',
                attributes: {
                  'data-model-action': 'auto',
                  'aria-pressed': 'true',
                  'title': 'Toggle auto-rotation',
                },
                [Component.text('↻ Auto')],
              ),
              button(
                classes: 'scene-ctl',
                attributes: {
                  'data-model-action': 'lighting',
                  'aria-pressed': 'false',
                  'title': 'Toggle Day / Evening lighting',
                },
                [Component.text('☀ Day')],
              ),
              button(
                classes: 'scene-ctl',
                attributes: {
                  'data-model-action': 'reset',
                  'title': 'Reset camera',
                },
                [Component.text('⟲ Reset')],
              ),
            ],
          ),
        ]),
      ]),
    ],
  );

  Component _glassCard(
    String label,
    String tag,
    String strongText,
    String smallText,
    bool active, {
    bool danger = false,
    String focus = 'patio',
    String parallaxDepth = '0.46',
  }) => button(
    classes:
        'glass-card${active ? ' active' : ''}${danger ? ' reg' : ''} parallax-target',
    attributes: {
      'type': 'button',
      'data-card-focus': focus,
      'data-parallax-depth': parallaxDepth,
    },
    events: events(
      onClick: () => setState(() {
        _benefit = danger ? 3 : (label == 'Location context' ? 1 : 2);
      }),
    ),
    [
      span(classes: 'label', [
        Component.text(label),
        em([Component.text(tag)]),
      ]),
      strong([Component.text(strongText)]),
      small([Component.text(smallText)]),
    ],
  );

  Component _camPreset(String label, String key, bool active) => button(
    classes: 'camera-preset${active ? ' active' : ''}',
    attributes: {'type': 'button', 'data-cam-preset': key},
    [Component.text(label)],
  );

  // -------------------------------------------------- section 01 problem

  Component _problem() => section(
    classes: 'section',
    id: 'problem',
    attributes: {'aria-labelledby': 'problemTitle'},
    [
      div(classes: 'wrap', [
        div(classes: 'section-head', [
          span(classes: 'eyebrow', [Component.text('01 · The challenge')]),
          const LetterRevealHeading(
            level: 2,
            id: 'problemTitle',
            runs: [
              LetterRun(
                'Choosing a location is more than choosing a property.',
              ),
            ],
            animateOnLoad: false,
          ),
          p([
            Component.text(
              'Entrepreneurs need to understand the space, its surroundings and '
              'whether the rent fits their business plan. Sitewise brings these '
              'considerations together in one place.',
            ),
          ]),
        ]),
        div(
          classes: 'challenge-pills',
          attributes: {
            'role': 'tablist',
            'aria-label': 'Compare traditional search vs Sitewise',
          },
          [
            for (var i = 0; i < 4; i++)
              button(
                classes: 'challenge-pill${_challenge == i ? ' active' : ''}',
                attributes: {
                  'type': 'button',
                  'role': 'tab',
                  'aria-selected': _challenge == i ? 'true' : 'false',
                },
                events: events(onClick: () => setState(() => _challenge = i)),
                [
                  span([Component.text('0${i + 1} · ${_topicLabel(i)}')]),
                ],
              ),
          ],
        ),
        div(classes: 'two', [
          article(classes: 'panel', [
            div([
              span(classes: 'tag ml', [
                Component.text('The problem · Traditional search'),
              ]),
              h3([Component.text(_challengeTitles[_challenge])]),
              p([Component.text(_challengeDesc[_challenge])]),
              ul(classes: 'bullet-points', [
                for (final b in _challengeBullets)
                  li([
                    i([Component.text('✕')]),
                    Component.text(b),
                  ]),
              ]),
            ]),
            div(classes: 'comparison-metrics', [
              div([
                div(classes: 'metric-row', [
                  span([Component.text('Fragmentation & Blind-Spot Risk')]),
                  b([Component.text('High · 6+ disconnected sources')]),
                ]),
                div(classes: 'metric-bar', [
                  i(
                    [],
                    classes: 'm',
                    styles: Styles(raw: {'width': '82%'}),
                  ),
                ]),
              ]),
            ]),
          ]),
          article(classes: 'panel solution-card', [
            div([
              span(classes: 'tag det', [
                Component.text('The Sitewise solution · Unified context'),
              ]),
              h3([
                Component.text('Explore, assess and decide with more context.'),
              ]),
              p([Component.text(_solutionDesc[_challenge])]),
              ul(classes: 'bullet-points', [
                for (final b in _solutionBullets)
                  li([
                    i([Component.text('✓')]),
                    Component.text(b),
                  ]),
              ]),
            ]),
            div(classes: 'comparison-metrics', [
              div([
                div(classes: 'metric-row', [
                  span([Component.text('Decision Context & Auditability')]),
                  b([Component.text('Unified · Explainable evidence chain')]),
                ]),
                div(classes: 'metric-bar', [
                  i(
                    [],
                    classes: 'd',
                    styles: Styles(raw: {'width': '94%'}),
                  ),
                ]),
              ]),
            ]),
          ]),
        ]),
        div(classes: 'clarity-meter-band', [
          div([
            span(classes: 'geo-map-kicker', [
              Component.text('BEFORE VS. AFTER READINESS METER'),
            ]),
            strong([
              Component.text(
                'Topic 0${_challenge + 1}: Information Consolidation',
              ),
            ]),
            p([
              Component.text(
                'Compare how much location context an entrepreneur has before '
                'arranging a physical viewing.',
              ),
            ]),
          ]),
          div(classes: 'clarity-bars', [
            _clarityBar('Before (Listing Only)', '28% Readiness', 28, 'stone'),
            _clarityBar(
              'With Sitewise (Map + Assessment + Report)',
              '92% Pre-Visit Readiness',
              92,
              'terracotta',
            ),
          ]),
        ]),
      ]),
    ],
  );

  String _topicLabel(int i) => [
    'Scattered Info',
    'Rent & Affordability',
    'Competitor & Catchment',
    'Missing Details & Risk',
  ][i];

  Component _clarityBar(String label, String val, int pct, String tone) => div([
    div(classes: 'metric-row', [
      span([Component.text(label)]),
      b([Component.text(val)]),
    ]),
    div(classes: 'metric-bar', [
      i(
        [],
        classes: tone,
        styles: Styles(raw: {'width': '$pct%'}),
      ),
    ]),
  ]);

  // -------------------------------------------------- section 02 explore

  Component _explore() => section(
    classes: 'section alt geo-explore-section',
    id: 'explore',
    attributes: {'aria-labelledby': 'exploreTitle'},
    [
      div(classes: 'wrap', [
        div(classes: 'geo-explore-heading', [
          div(classes: 'geo-explore-heading-copy', [
            span(classes: 'eyebrow', [
              Component.text('02 · PROPERTY & LOCATION EXPLORATION'),
            ]),
            const LetterRevealHeading(
              level: 2,
              id: 'exploreTitle',
              runs: [LetterRun('See what surrounds each property.')],
              animateOnLoad: false,
            ),
          ]),
          p([
            Component.text(
              'Go beyond rental price. Explore nearby F&B activity, '
              'neighbourhood context and property details together in one place.',
            ),
          ]),
        ]),
        div(classes: 'geo-explore-layout', [
          div(classes: 'geo-map-panel', [
            div(classes: 'geo-map-topbar', [
              div([
                span(classes: 'geo-map-kicker', [
                  Component.text('LOCATION INTELLIGENCE'),
                ]),
                h3([Component.text('Explore the neighbourhood')]),
              ]),
              div(
                classes: 'radius-selector',
                attributes: {
                  'role': 'group',
                  'aria-label': 'Catchment radius toggle',
                },
                [
                  button(
                    classes: 'radius-btn',
                    attributes: {'type': 'button'},
                    [Component.text('500m Walk')],
                  ),
                  button(
                    classes: 'radius-btn active',
                    attributes: {'type': 'button'},
                    [Component.text('1.5km Drive')],
                  ),
                ],
              ),
            ]),
            div(
              classes: 'map-graphic geo-map-graphic',
              attributes: {
                'aria-label':
                    'Illustrative map showing a selected property and surrounding area layers',
              },
              [
                span(classes: 'park p1', []),
                span(classes: 'park p2', []),
                span(classes: 'park p3', []),
                span(classes: 'map-route', []),
                div(classes: 'catchment-radar', []),
                for (final pin in [
                  ['food', '26%', '28%', '☕', 'food1', 'food'],
                  ['food', '62%', '34%', '🍜', 'food2', 'food'],
                  [
                    'population',
                    '71%',
                    '25%',
                    '🏢',
                    'population',
                    'population',
                  ],
                  ['transit', '75%', '62%', '🚆', 'transit', 'transit'],
                  ['amenities', '26%', '71%', '🎓', 'amenities', 'amenities'],
                ])
                  if (_layers.contains(pin[5]))
                    button(
                      classes:
                          'map-pin ${pin[0]}${pin[4] == 'food1' ? ' active' : ''}',
                      attributes: {
                        'type': 'button',
                        'style': 'left:${pin[1]};top:${pin[2]};',
                        'title': 'Nearby ${pin[0]}',
                      },
                      [Component.text(pin[3])],
                    ),
                button(
                  classes: 'map-marker',
                  attributes: {'type': 'button', 'title': 'Selected property'},
                  [
                    span([Component.text('⌖')]),
                  ],
                ),
                span(classes: 'geo-map-corner-label', [
                  Component.text('AREA VIEW '),
                  b([Component.text('1.5 KM')]),
                ]),
              ],
            ),
            div(
              classes: 'pin-inspector-bar',
              attributes: {'aria-live': 'polite'},
              [
                div([
                  small([Component.text('F&B PLACES · 240M WALK')]),
                  strong([Component.text('Artisan Roastery & Bakery Cluster')]),
                  p([
                    Component.text(
                      'Active brunch & coffee footfall; validates specialty F&B '
                      'demand in this block.',
                    ),
                  ]),
                ]),
                span(classes: 'tag det', [Component.text('Layer Active')]),
              ],
            ),
            div(classes: 'geo-layer-header', [
              span([Component.text('Explore map layers')]),
              small([Component.text('Toggle layers or click any pin above')]),
            ]),
            div(
              classes: 'map-toggles geo-map-toggles',
              attributes: {'aria-label': 'Illustrative map layers'},
              [
                _layerToggle('food', 'F&B places (14)'),
                _layerToggle('population', 'Population (42.8k)'),
                _layerToggle('transit', 'Access (3 nodes)'),
                _layerToggle('amenities', 'Amenities (6 anchors)'),
              ],
            ),
            div(classes: 'geo-map-footnote', [
              span(classes: 'geo-footnote-mark', [Component.text('i')]),
              span([
                Component.text(
                  'Map layers represent the types of information Sitewise can '
                  'present. Actual coverage depends on available data.',
                ),
              ]),
            ]),
          ]),
          div(classes: 'geo-explore-details', [
            div(classes: 'geo-details-title', [
              span(classes: 'geo-map-kicker', [
                Component.text('WHAT YOU CAN FIND OUT'),
              ]),
              h3([
                Component.text(
                  'Understand the location, not just the listing.',
                ),
              ]),
              p([
                Component.text(
                  'Click any card below to highlight the corresponding map signals.',
                ),
              ]),
            ]),
            _benefitCard(
              1,
              '⌖',
              'Nearby F&B activity',
              'Review surrounding F&B places to understand the local competitive landscape.',
              'Live preview: 14 F&B outlets within 1.5km · 4 cafés, 6 casual dining, 4 QSR.',
              'Competitor context',
            ),
            _benefitCard(
              2,
              '◎',
              'Neighbourhood & access',
              'Explore available population context, access and nearby amenities.',
              'Live preview: ~42,800 catchment population · Arterial road turn-in + 240 parking bays.',
              'Area insights',
            ),
            _benefitCard(
              3,
              '↔',
              'Property comparison',
              'Compare rent, space and property features against your business needs.',
              'Live preview: EP-01037 · RM 10,000/mo · 2,400 sqft (RM 4.17 psf) · Corner frontage.',
              'Shortlist with context',
            ),
            a(classes: 'geo-explore-cta', href: '#assessment', [
              span([Component.text('Next: tell us about your business')]),
              b(attributes: {'aria-hidden': 'true'}, [Component.text('↗')]),
            ]),
          ]),
        ]),
      ]),
    ],
  );

  Component _layerToggle(String layer, String label) => button(
    classes: 'layer-toggle${_layers.contains(layer) ? ' active' : ''}',
    attributes: {
      'type': 'button',
      'aria-pressed': _layers.contains(layer) ? 'true' : 'false',
    },
    events: events(
      onClick: () => setState(() {
        if (_layers.contains(layer)) {
          _layers.remove(layer);
        } else {
          _layers.add(layer);
        }
      }),
    ),
    [i([], classes: 'layer-dot $layer-dot'), Component.text(label)],
  );

  Component _benefitCard(
    int n,
    String icon,
    String title,
    String body,
    String live,
    String tag,
  ) => button(
    classes: 'geo-benefit-card${_benefit == n ? ' active' : ''}',
    attributes: {'type': 'button'},
    events: events(onClick: () => setState(() => _benefit = n)),
    [
      span(classes: 'geo-benefit-number', [Component.text('0$n')]),
      span(classes: 'geo-benefit-icon', [Component.text(icon)]),
      div([
        h4([Component.text(title)]),
        p([Component.text(body)]),
        div(classes: 'geo-benefit-live', [Component.text(live)]),
        span(classes: 'geo-benefit-tag', [Component.text(tag)]),
      ]),
    ],
  );

  // ------------------------------------------------ section 03 assessment

  Component _assessment() => section(
    classes: 'section',
    id: 'assessment',
    attributes: {'aria-labelledby': 'assessmentTitle'},
    [
      div(classes: 'wrap', [
        div(classes: 'section-head', [
          span(classes: 'eyebrow', [
            Component.text('03 · Business assessment'),
          ]),
          const LetterRevealHeading(
            level: 2,
            id: 'assessmentTitle',
            runs: [LetterRun('Start with your business needs.')],
            animateOnLoad: false,
          ),
          p([
            Component.text(
              'Answer a short questionnaire so Sitewise can consider your F&B '
              'concept, budget and property requirements.',
            ),
          ]),
        ]),
        div(
          classes: 'workflow',
          attributes: {
            'role': 'tablist',
            'aria-label': '4-step business assessment',
          },
          [
            for (var s = 1; s <= 4; s++)
              button(
                classes: 'step${_assessStep == s ? ' active' : ''}',
                attributes: {
                  'type': 'button',
                  'role': 'tab',
                  'aria-selected': _assessStep == s ? 'true' : 'false',
                },
                events: events(onClick: () => setState(() => _assessStep = s)),
                [
                  span(classes: 'stepno', [Component.text('STEP 0$s')]),
                  div(classes: 'step-icon', [
                    Component.text(['☷', '＄', '⌂', '✓'][s - 1]),
                  ]),
                  h3([
                    Component.text(
                      [
                        'Share your business plan',
                        'Set your budget',
                        'Choose property requirements',
                        'Review your assessment',
                      ][s - 1],
                    ),
                  ]),
                  p([
                    Component.text(
                      [
                        'Tell us your F&B concept, target customers and operating needs.',
                        'Enter your rental budget and expected monthly sales to review affordability.',
                        'Set your preferred area, space, facilities and essential conditions.',
                        'Check your answers, calculations and any information that still needs confirmation.',
                      ][s - 1],
                    ),
                  ]),
                ],
              ),
          ],
        ),
        div(
          classes: 'interactive-stage',
          attributes: {'aria-live': 'polite'},
          [
            _assessTopbar(),
            if (_assessStep == 1) _assessView1(),
            if (_assessStep == 2) _assessView2(),
            if (_assessStep == 3) _assessView3(),
            if (_assessStep == 4) _assessView4(),
          ],
        ),
      ]),
    ],
  );

  Component _assessTopbar() => div(classes: 'stage-topbar', [
    div([
      span(classes: 'tag ml', [
        Component.text('STEP 0$_assessStep OF 04 · BUSINESS PLAN'),
      ]),
      strong([
        Component.text(
          [
            'Select your F&B concept, customer profile & operating hours',
            'Review your rent affordability against your concept benchmark',
            'Toggle essential facility & MEP conditions',
            'Review your assessment summary',
          ][_assessStep - 1],
        ),
      ]),
    ]),
    div(classes: 'stage-nav-btns', [
      button(
        classes: 'btn sm',
        attributes: {'type': 'button'},
        events: events(
          onClick: () => setState(() {
            if (_assessStep > 1) _assessStep--;
          }),
        ),
        [Component.text('← Previous')],
      ),
      button(
        classes: 'btn primary sm',
        attributes: {'type': 'button'},
        events: events(
          onClick: () => setState(() {
            if (_assessStep < 4) _assessStep++;
          }),
        ),
        [Component.text('Next step →')],
      ),
    ]),
  ]);

  Component _assessView1() => div(classes: 'assess-view', [
    span(classes: 'geo-map-kicker', [
      Component.text('1. CHOOSE YOUR F&B CONCEPT'),
    ]),
    div(classes: 'concept-grid', [
      for (var i = 0; i < _concepts.length; i++)
        button(
          classes: 'concept-btn${_concept == i ? ' active' : ''}',
          attributes: {'type': 'button'},
          events: events(onClick: () => setState(() => _concept = i)),
          [
            strong([
              Component.text(
                '${_concepts[i]['emoji']} ${_concepts[i]['name']}',
              ),
            ]),
            small([Component.text(_concepts[i]['small'] as String)]),
          ],
        ),
    ]),
    div(classes: 'two', [
      div([
        span(classes: 'geo-map-kicker', [
          Component.text('2. TARGET CUSTOMER PROFILE'),
        ]),
        div(classes: 'option-pills', [
          _pill('Students & Young Families'),
          _pill('Office Crowd'),
          _pill('Delivery & Takeaway'),
        ]),
      ]),
      div([
        span(classes: 'geo-map-kicker', [
          Component.text('3. OPERATING WINDOW'),
        ]),
        div(classes: 'option-pills', [
          _pill('All-Day (8am – 10pm)'),
          _pill('Daytime (7am – 5pm)'),
          _pill('Evening & Supper'),
        ]),
      ]),
    ]),
  ]);

  Component _pill(String label) => button(
    classes: 'option-pill',
    attributes: {'type': 'button'},
    [Component.text(label)],
  );

  Component _assessView2() => div(classes: 'assess-view', [
    div(classes: 'two', [
      div([
        div(classes: 'slider-group', [
          div(classes: 'slider-label', [
            span([Component.text('Sample Property Monthly Rent (EP-01037)')]),
            b([
              Component.text(
                'RM ${_rent.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}',
              ),
            ]),
          ]),
          input(
            type: InputType.range,
            attributes: {
              'min': '5000',
              'max': '25000',
              'step': '500',
              'value': '$_rent',
              'aria-label': 'Monthly Rent',
            },
            events: events<String>(
              onInput: (v) => setState(() {
                _rent = int.tryParse(v) ?? _rent;
              }),
            ),
          ),
        ]),
        div(classes: 'slider-group', [
          div(classes: 'slider-label', [
            label(htmlFor: 'rev', [
              Component.text('Expected Monthly Sales / Revenue (RM)'),
            ]),
            input(
              type: InputType.number,
              attributes: {
                'id': 'rev',
                'min': '10000',
                'max': '300000',
                'step': '1000',
                'value': '$_revenue',
                'aria-label': 'Expected Monthly Revenue in RM',
              },
              events: events<String>(
                onInput: (v) => setState(() {
                  _revenue = int.tryParse(v) ?? _revenue;
                }),
              ),
            ),
          ]),
          input(
            type: InputType.range,
            attributes: {
              'min': '35000',
              'max': '220000',
              'step': '5000',
              'value': '$_revenue',
              'aria-label': 'Expected Monthly Sales Slider',
            },
            events: events<String>(
              onInput: (v) => setState(() {
                _revenue = int.tryParse(v) ?? _revenue;
              }),
            ),
          ),
        ]),
        div(classes: 'chain', [
          _chainLink(
            '1. Deterministic Evidence',
            'Rent RM $_rent ÷ revenue RM $_revenue = ${_ratio.toStringAsFixed(1)}%',
          ),
          _chainLink(
            '2. Benchmark Finding',
            _onTrack
                ? 'ON_TRACK · Deviation ${(_ratio - _bench).toStringAsFixed(1)} points from the $_bench% ${_concepts[_concept]['name']} benchmark.'
                : 'ABOVE BENCHMARK · Rent consumes ${(_ratio - _bench).toStringAsFixed(1)} points over the $_bench% benchmark.',
          ),
          _chainLink(
            '3. Actionable Recommendation',
            _onTrack
                ? 'No corrective action required. Validate daily footfall assumptions during site visit.'
                : 'Consider a lower rent, higher sales plan, or a different concept benchmark before committing.',
          ),
        ]),
      ]),
      div(classes: 'ratio-gauge-box', [
        div(classes: 'ratio-gauge-top', [
          div([
            span(classes: 'gauge-label', [
              Component.text('RENT-TO-REVENUE RATIO'),
            ]),
            div(classes: 'status-wrap', [
              span(classes: 'status ${_onTrack ? 's-ok' : 's-hi'}', [
                Component.text(_onTrack ? 'ON_TRACK' : 'HIGH_RISK'),
              ]),
            ]),
          ]),
          span(classes: 'big', [
            Component.text('${_ratio.toStringAsFixed(1)}%'),
          ]),
        ]),
        div(classes: 'gauge-track', [
          div(
            classes: 'gauge-fill',
            styles: Styles(raw: {'width': '$_fill%'}),
            [],
          ),
        ]),
        div(classes: 'gauge-legend', [
          span([Component.text('0% (Healthy)')]),
          span([Component.text('Benchmark: ≤ $_bench%')]),
          span([Component.text('20%+ (High Risk)')]),
        ]),
        p(classes: 'gauge-rule', [
          Component.text(
            'Deterministic rule: Monthly Rent ÷ Expected Monthly Sales compared '
            'against your concept benchmark ($_bench%).',
          ),
        ]),
      ]),
    ]),
  ]);

  Component _chainLink(String label, String body) => div(classes: 'link', [
    small([Component.text(label)]),
    span([Component.text(body)]),
  ]);

  Component _assessView3() => div(classes: 'assess-view', [
    div(classes: 'slider-group', [
      div(classes: 'slider-label', [
        span([Component.text('Preferred Floor Area')]),
        b([
          Component.text(
            '${_floorArea.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')} sqft',
          ),
        ]),
      ]),
      input(
        type: InputType.range,
        attributes: {
          'min': '800',
          'max': '4000',
          'step': '100',
          'value': '$_floorArea',
          'aria-label': 'Preferred Floor Area',
        },
        events: events<String>(
          onInput: (v) => setState(() {
            _floorArea = int.tryParse(v) ?? _floorArea;
          }),
        ),
      ),
    ]),
    div([
      span(classes: 'geo-map-kicker', [
        Component.text('TOGGLE ESSENTIAL FACILITY & MEP CONDITIONS'),
      ]),
      div(classes: 'req-grid', [
        for (final r in _reqOptions)
          label(classes: 'req-check', [
            input(
              type: InputType.checkbox,
              attributes: {
                'value': r,
                if (_reqs.contains(r)) 'checked': 'checked',
              },
              events: events(
                onClick: () => setState(() {
                  if (_reqs.contains(r)) {
                    _reqs.remove(r);
                  } else {
                    _reqs.add(r);
                  }
                }),
              ),
            ),
            Component.text(r),
          ]),
      ]),
    ]),
  ]);

  Component _assessView4() => div(classes: 'assess-view', [
    div(classes: 'summary-boxes', [
      _summaryBox(
        'Selected Concept',
        _concepts[_concept]['name'] as String,
        'All-Day (8am – 10pm)',
      ),
      _summaryBox(
        'Rent Affordability',
        '${_ratio.toStringAsFixed(1)}% (${_onTrack ? 'ON_TRACK' : 'HIGH_RISK'})',
        'RM $_rent / $_revenue sales',
      ),
      _summaryBox(
        'Essential Specs',
        '${_reqs.length} Required Conditions',
        'Target: $_floorArea sqft',
      ),
      _summaryBox(
        'Items to Confirm',
        '2 UNKNOWN Specs',
        'Exhaust flue & F&B license',
      ),
    ]),
    div(classes: 'verify-note', [
      span([
        Component.text('Verification note: '),
        strong([
          Component.text(
            'Regulatory F&B approval and exhaust ducting status on EP-01037 are '
            'marked UNKNOWN and must be confirmed with the landlord during viewing.',
          ),
        ]),
      ]),
      a(classes: 'btn primary sm', href: '#recommendations', [
        Component.text('View Recommendations ↓'),
      ]),
    ]),
  ]);

  Component _summaryBox(String label, String strong, String sub) =>
      div(classes: 'summary-box', [
        small([Component.text(label)]),
        b([Component.text(strong)]),
        span([Component.text(sub)]),
      ]);

  // -------------------------------------------- section 04 recommendations

  Component _recommendations() => section(
    classes: 'section alt',
    id: 'recommendations',
    attributes: {'aria-labelledby': 'recommendationsTitle'},
    [
      div(classes: 'wrap', [
        div(classes: 'section-head', [
          span(classes: 'eyebrow', [
            Component.text('04 · Recommendations and report'),
          ]),
          const LetterRevealHeading(
            level: 2,
            id: 'recommendationsTitle',
            runs: [LetterRun('Understand why a property may fit your needs.')],
            animateOnLoad: false,
          ),
          p([
            Component.text(
              'Review candidate properties, the factors behind recommendations '
              'and the questions to resolve before making a commitment.',
            ),
          ]),
        ]),
        div(
          classes: 'workflow',
          attributes: {
            'role': 'tablist',
            'aria-label': '4 recommendation and report outputs',
          },
          [
            for (var t = 1; t <= 4; t++)
              button(
                classes: 'step${_recTab == t ? ' active' : ''}',
                attributes: {
                  'type': 'button',
                  'role': 'tab',
                  'aria-selected': _recTab == t ? 'true' : 'false',
                },
                events: events(onClick: () => setState(() => _recTab = t)),
                [
                  span(classes: 'stepno', [Component.text('0$t')]),
                  div(classes: 'step-icon', [
                    Component.text(['✦', '☷', '◉', '▤'][t - 1]),
                  ]),
                  h3([
                    Component.text(
                      [
                        'Property recommendations',
                        'Clear explanations',
                        '360° virtual tour',
                        'Business location report',
                      ][t - 1],
                    ),
                  ]),
                  p([
                    Component.text(
                      [
                        'Review ranked options based on available property data and your requirements.',
                        'See the factors that support a recommendation, possible drawbacks and missing information.',
                        'Explore available panoramic views before arranging an in-person visit.',
                        'Bring your requirements, property comparisons, analysis and follow-up checks into one report.',
                      ][t - 1],
                    ),
                  ]),
                ],
              ),
          ],
        ),
        div(
          classes:
              'interactive-stage${_recTab == 1 ? ' interactive-stage--ranked' : ''}',
          attributes: {'aria-live': 'polite'},
          [
            if (_recTab == 1) _recView1(),
            if (_recTab == 2) _recView2(),
            if (_recTab == 3) _recView3(),
            if (_recTab == 4) _recView4(),
          ],
        ),
      ]),
    ],
  );

  Component _recView1() => div(classes: 'rec-view rec-view--ranked', [
    div(classes: 'stage-topbar', [
      div(classes: 'stage-topbar__copy', [
        span(classes: 'tag det', [
          Component.text('01 · RANKED PROPERTY RECOMMENDATIONS'),
        ]),
        strong([
          Component.text('Candidate properties matched to your assessment'),
        ]),
      ]),
      button(
        classes: 'btn sm',
        attributes: {'type': 'button'},
        events: events(onClick: () => setState(() => _recTab = 2)),
        [Component.text('See factor explanations →')],
      ),
    ]),
    div(classes: 'candidate-grid', [
      for (var i = 0; i < _candidates.length; i++)
        div(classes: 'candidate-card${_recProp == i ? ' active' : ''}', [
          div([
            div(classes: 'cand-head', [
              span(classes: 'stepno', [
                Component.text(_candidates[i]['rank']!),
              ]),
              span(classes: 'score-badge', [
                Component.text(_candidates[i]['fit']!),
              ]),
            ]),
            h4([Component.text(_candidates[i]['name']!)]),
            p([Component.text(_candidates[i]['meta']!)]),
            div(classes: 'cand-tags', [
              span(classes: 'tag det', [Component.text(_candidates[i]['t1']!)]),
              if (_candidates[i]['t2']!.isNotEmpty)
                span(classes: 'tag ${_candTagTone(_candidates[i]['t2']!)}', [
                  Component.text(_candidates[i]['t2']!),
                ]),
              if (_candidates[i]['t3']!.isNotEmpty)
                span(classes: 'tag warn', [
                  Component.text(_candidates[i]['t3']!),
                ]),
            ]),
          ]),
          button(
            classes:
                'btn ${_recProp == i ? 'primary sm' : 'sm'} select-prop-btn',
            attributes: {'type': 'button'},
            events: events(onClick: () => setState(() => _recProp = i)),
            [
              Component.text(
                _recProp == i ? 'Selected for Report ✓' : 'Select / Compare',
              ),
            ],
          ),
        ]),
    ]),
  ]);

  /// Tone for the second candidate tag: a hard constraint breach reads as a
  /// risk (red), a missing spec as a caution (amber), everything else as
  /// neutral information (blue).
  static String _candTagTone(String text) {
    if (text.contains('Above') || text.contains('HIGH_RISK')) return 'danger';
    if (text.contains('UNKNOWN')) return 'warn';
    return 'ml';
  }

  Component _recView2() => div(classes: 'rec-view', [
    div(classes: 'stage-topbar', [
      div([
        span(classes: 'tag ml', [
          Component.text('02 · EXPLAINABLE SCORING FACTORS'),
        ]),
        strong([
          Component.text(
            'Why EP-01037 (Shah Alam) is recommended — and what to verify',
          ),
        ]),
      ]),
      button(
        classes: 'btn sm',
        attributes: {'type': 'button'},
        [Component.text('Open 360° virtual tour →')],
      ),
    ]),
    div(classes: 'two', [
      div(classes: 'weight-list', [
        for (final w in _weights)
          div(classes: 'weight-row', [
            span([Component.text(w['label']!)]),
            div(classes: 'bar', [
              i([], styles: Styles(raw: {'width': w['pct']!})),
            ]),
            b([Component.text(w['pct']!)]),
          ]),
      ]),
      div(classes: 'explanation-cards', [
        div(classes: 'pro-card', [
          strong(classes: 'pro-title', [
            Component.text('Supporting factors (Pros)'),
          ]),
          p([
            Component.text(
              'Monthly rent (RM 10,000) stays within your concept affordability '
              'benchmark; 32ft corner frontage provides strong signage visibility '
              'and patio seating potential.',
            ),
          ]),
        ]),
        div(classes: 'warn-card', [
          strong(classes: 'warn-title', [
            Component.text('Missing information (UNKNOWN — Verify on site)'),
          ]),
          p([
            Component.text(
              'F&B municipal licensing status, rooftop kitchen exhaust riser '
              'approval, and grease trap capacity are unverified in listing data.',
            ),
          ]),
        ]),
      ]),
    ]),
  ]);

  Component _recView3() => div(classes: 'rec-view', [
    div(classes: 'stage-topbar', [
      div([
        span(classes: 'tag ml', [
          Component.text('03 · INTERACTIVE 360° VIRTUAL TOUR'),
        ]),
        strong([
          Component.text(
            'Drag to pan around EP-01037 or click numbered inspection hotspots',
          ),
        ]),
      ]),
      span(classes: 'tour-compass', [Component.text('Heading: 125° SE')]),
    ]),
    div(
      classes: 'tour-viewport',
      attributes: {'aria-label': 'Interactive 360 degree virtual tour'},
      [
        div(classes: 'pano-stage', [
          div(classes: 'pano-room-grid', []),
          div(classes: 'pano-window', []),
          div(classes: 'pano-counter', []),
          for (var i = 0; i < _hotspots.length; i++)
            button(
              classes: 'hotspot-btn${_hotspot == i + 1 ? ' active' : ''}',
              attributes: {
                'type': 'button',
                'style': _hotspotStyle(i),
                'title': _hotspots[i]['title']!,
              },
              events: events(onClick: () => setState(() => _hotspot = i + 1)),
              [Component.text('${i + 1}')],
            ),
        ]),
        div(classes: 'tour-hud-top', [
          span(classes: 'tour-badge', [
            Component.text('360° PANORAMA · DRAG LEFT / RIGHT TO PAN'),
          ]),
          span(classes: 'tour-badge', [Component.text('EP-01037 · SHAH ALAM')]),
        ]),
      ],
    ),
    div(classes: 'hotspot-readout', [
      strong([Component.text(_hotspots[_hotspot - 1]['title']!)]),
      p([
        Component.text(
          [
            'Corner frontage with strong street visibility and a patio apron for alfresco seating.',
            'Rooftop kitchen exhaust riser — UNKNOWN approval status; verify with landlord.',
            'Open dining floor span suitable for ~60 covers at peak.',
            'Alfresco patio apron approved for 6 tables; confirm with local council.',
          ][_hotspot - 1],
        ),
      ]),
    ]),
  ]);

  String _hotspotStyle(int i) {
    final pos = [
      'left:26%;top:38%;',
      'left:52%;top:26%;',
      'left:72%;top:56%;',
      'left:40%;top:70%;',
    ];
    return pos[i];
  }

  Component _recView4() => div(classes: 'rec-view', [
    div(classes: 'stage-topbar', [
      div([
        span(classes: 'tag det', [
          Component.text('04 · BUSINESS LOCATION REPORT'),
        ]),
        strong([
          Component.text(
            'One report: requirements, comparison, analysis, follow-ups',
          ),
        ]),
      ]),
      button(
        classes: 'btn primary sm',
        attributes: {'type': 'button'},
        [Component.text('Download report ↗')],
      ),
    ]),
    div(classes: 'report-preview', [
      div(classes: 'rp-block', [
        span(classes: 'rp-k', [Component.text('Concept')]),
        b([Component.text(_concepts[_concept]['name'] as String)]),
      ]),
      div(classes: 'rp-block', [
        span(classes: 'rp-k', [Component.text('Affordability')]),
        b([
          Component.text(
            '${_ratio.toStringAsFixed(1)}% · ${_onTrack ? 'ON_TRACK' : 'HIGH_RISK'}',
          ),
        ]),
      ]),
      div(classes: 'rp-block', [
        span(classes: 'rp-k', [Component.text('Recommended')]),
        b([Component.text(_candidates[_recProp]['name']!)]),
      ]),
      div(classes: 'rp-block rp-warn', [
        span(classes: 'rp-k', [Component.text('Verify on site')]),
        b([Component.text('2 UNKNOWN specs')]),
      ]),
    ]),
  ]);

  // ------------------------------------------------------------- footer

  Component _footer() => footer(classes: 'site-footer', [
    div(classes: 'wrap footer-grid', [
      div(classes: 'footer-brand', [
        div(classes: 'footer-brand__row', [
          span(classes: 'brand-icon-sm', [Component.text('◉')]),
          strong([Component.text('SITEWISE')]),
        ]),
        p([
          Component.text(
            'F&B Location Intelligence for entrepreneurs who want the evidence '
            'before they commit.',
          ),
        ]),
      ]),
      div(classes: 'footer-col', [
        strong([Component.text('Explore')]),
        a(href: '#problem', [Component.text('Problem & solution')]),
        a(href: '#explore', [Component.text('Location exploration')]),
        a(href: '#assessment', [Component.text('Business assessment')]),
        a(href: '#recommendations', [
          Component.text('Recommendations & report'),
        ]),
      ]),
      div(classes: 'footer-col', [
        strong([Component.text('Get started')]),
        AppLink(to: '/login', children: [Component.text('Sign in')]),
        AppLink(to: '/signup', children: [Component.text('Create an account')]),
        AppLink(
          to: '/entrepreneur',
          children: [Component.text('Entrepreneur workspace')],
        ),
      ]),
      div(classes: 'footer-col footer-col--note', [
        strong([Component.text('Note')]),
        p(classes: 'footer-fine', [
          Component.text(
            'Sample property EP-01037 and all metrics are illustrative. '
            'Regulatory and technical status is UNKNOWN until verified on site.',
          ),
        ]),
      ]),
    ]),
    div(classes: 'footer-base', [
      div(classes: 'wrap footer-base__inner', [
        span([Component.text('© Sitewise · Illustrative demo')]),
        span([Component.text('No revenue forecasts claimed.')]),
      ]),
    ]),
  ]);
}
