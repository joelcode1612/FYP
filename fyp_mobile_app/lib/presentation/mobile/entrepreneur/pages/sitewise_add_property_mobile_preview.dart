import 'package:flutter/material.dart';

import '../../shell/mobile_app_shell.dart';

/// SiteWise Add Property — Flutter mobile presentation preview.
///
/// This is a self-contained, presentation-only screen. It recreates the
/// five-step mobile Add Property experience and uses local in-memory state.
/// It does NOT call FastAPI or Supabase, upload photos, geocode an address,
/// or create a property record.
///
/// Suggested location:
///   fyp_mobile_app/lib/presentation/mobile/
///     sitewise_add_property_mobile_preview.dart
///
/// Preview usage:
///   const SitewiseAddPropertyMobilePreview()
///
/// Replace this preview with the real mobile use case only after mapping the
/// existing mobile form state, validation, media workflow and API contract.
class SitewiseAddPropertyMobilePreview extends StatefulWidget {
  const SitewiseAddPropertyMobilePreview({super.key});

  @override
  State<SitewiseAddPropertyMobilePreview> createState() =>
      _SitewiseAddPropertyMobilePreviewState();
}

class _SitewiseAddPropertyMobilePreviewState
    extends State<SitewiseAddPropertyMobilePreview> {
  static const Color _brand = Color(0xFF2F6FED);
  static const Color _brandStrong = Color(0xFF1D4ED8);
  static const Color _background = Color(0xFFF6F7F9);
  static const Color _ink = Color(0xFF10151F);
  static const Color _muted = Color(0xFF58677D);
  static const Color _border = Color(0xFFE2E8F0);

  static const List<String> _stepNames = <String>[
    'Property details',
    'Location',
    'Photos',
    'Review',
    'Confirmation',
  ];

  static const List<String> _stepDescriptions = <String>[
    'Enter the basic details of your commercial unit.',
    'Add the property address and check its location.',
    'Prepare the photos for your property profile.',
    'Review the information before submission.',
    'Preview the confirmation screen.',
  ];

  final TextEditingController _nameController =
      TextEditingController(text: 'SS15 Corner Retail');
  final TextEditingController _rentController =
      TextEditingController(text: '7800');
  final TextEditingController _areaController =
      TextEditingController(text: '1680');
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _stateController =
      TextEditingController(text: 'Selangor');
  final TextEditingController _districtController =
      TextEditingController(text: 'Petaling');
  final TextEditingController _postcodeController = TextEditingController();
  final TextEditingController _latitudeController = TextEditingController();
  final TextEditingController _longitudeController = TextEditingController();

  int _step = 1;
  String _propertyType = 'Shoplot';
  String? _validationMessage;

  String get _propertyName => _nameController.text.trim();
  String get _monthlyRent => _rentController.text.trim();
  String get _builtUpArea => _areaController.text.trim();
  String get _address => _addressController.text.trim();
  String get _stateName => _stateController.text.trim();
  String get _district => _districtController.text.trim();
  String get _postcode => _postcodeController.text.trim();
  String get _latitude => _latitudeController.text.trim();
  String get _longitude => _longitudeController.text.trim();

  @override
  void dispose() {
    _nameController.dispose();
    _rentController.dispose();
    _areaController.dispose();
    _addressController.dispose();
    _stateController.dispose();
    _districtController.dispose();
    _postcodeController.dispose();
    _latitudeController.dispose();
    _longitudeController.dispose();
    super.dispose();
  }

  String _display(String value) => value.isEmpty ? 'Not provided' : value;

  bool _validateCurrentStep() {
    if (_step == 1) {
      if (_propertyName.isEmpty) {
        _validationMessage = 'Enter a property name to continue.';
        return false;
      }

      final rent = double.tryParse(_monthlyRent);
      if (rent == null || rent <= 0) {
        _validationMessage = 'Enter a valid monthly rental greater than zero.';
        return false;
      }

      final area = double.tryParse(_builtUpArea);
      if (area == null || area <= 0) {
        _validationMessage = 'Enter a valid built-up area greater than zero.';
        return false;
      }
    }

    if (_step == 2) {
      if (_address.isEmpty || _stateName.isEmpty || _district.isEmpty) {
        _validationMessage = 'Address, state and district are required.';
        return false;
      }

      final hasLatitude = _latitude.isNotEmpty;
      final hasLongitude = _longitude.isNotEmpty;
      if (hasLatitude != hasLongitude) {
        _validationMessage =
            'Enter both latitude and longitude, or leave both blank.';
        return false;
      }

      if (hasLatitude && hasLongitude) {
        final latitude = double.tryParse(_latitude);
        final longitude = double.tryParse(_longitude);
        if (latitude == null ||
            longitude == null ||
            latitude < -90 ||
            latitude > 90 ||
            longitude < -180 ||
            longitude > 180) {
          _validationMessage = 'Enter valid latitude and longitude values.';
          return false;
        }
      }
    }

    _validationMessage = null;
    return true;
  }

  void _goNext() {
    if (_step >= 5) return;
    setState(() {
      if (_validateCurrentStep()) {
        _step += 1;
        _validationMessage = null;
      }
    });
  }

  void _goBack() {
    if (_step <= 1) return;
    setState(() {
      _step -= 1;
      _validationMessage = null;
    });
  }

  void _editStep(int step) {
    setState(() {
      _step = step;
      _validationMessage = null;
    });
  }

  void _onTextChanged(String _) {
    setState(() {
      _validationMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: _background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _brand,
          primary: _brand,
          surface: Colors.white,
        ),
        fontFamily: 'Archivo',
      ),
      child: MobileAppShell(
        title: 'Add property',
        currentRoute: '/entrepreneur/add-property',
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 28),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 620),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        // The shared MobileAppShell provides the real
                        // SiteWise top bar and floating bottom dock.
                        _buildBreadcrumb(),
                        const SizedBox(height: 18),
                        _buildPageHeading(),
                        const SizedBox(height: 18),
                        _buildStepper(),
                        const SizedBox(height: 18),
                        _buildMainCard(),
                        const SizedBox(height: 18),
                        _buildPropertySnapshot(),
                        const SizedBox(height: 14),
                        _buildWorkflowNote(),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildBreadcrumb() {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: const <Widget>[
        Text('Home', style: _breadcrumbStyle),
        Icon(Icons.chevron_right_rounded, size: 15, color: _muted),
        Text('My Properties', style: _breadcrumbStyle),
        Icon(Icons.chevron_right_rounded, size: 15, color: _muted),
        Text('Add Property', style: _breadcrumbStyle),
      ],
    );
  }

  static const TextStyle _breadcrumbStyle = TextStyle(
    color: _muted,
    fontSize: 12,
    fontWeight: FontWeight.w700,
  );

  Widget _buildPageHeading() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'ENTREPRENEUR WORKSPACE',
          style: TextStyle(
            color: _brandStrong,
            fontSize: 10,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.6,
          ),
        ),
        const SizedBox(height: 7),
        const Text(
          'Add commercial property',
          style: TextStyle(
            color: _ink,
            fontSize: 25,
            height: 1.15,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.8,
          ),
        ),
        const SizedBox(height: 7),
        const Text(
          'Build a complete commercial-property profile before assessment.',
          style: TextStyle(
            color: _muted,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 13),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0xFFEDF4FF),
            border: Border.all(color: const Color(0xFFD4E3FB)),
            borderRadius: BorderRadius.circular(30),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.circle, color: _brand, size: 7),
              SizedBox(width: 7),
              Text(
                'Presentation preview',
                style: TextStyle(
                  color: _brandStrong,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStepper() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: List<Widget>.generate(5, (index) {
          final stepNumber = index + 1;
          final isCurrent = stepNumber == _step;
          final isDone = stepNumber < _step;
          return Expanded(
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Center(
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isCurrent
                            ? _brand
                            : isDone
                                ? const Color(0xFFEDF4FF)
                                : const Color(0xFFF6F8FC),
                        border: Border.all(
                          color: isCurrent
                              ? _brand
                              : isDone
                                  ? const Color(0xFFCFE0FD)
                                  : const Color(0xFFD6DEEA),
                        ),
                      ),
                      child: Center(
                        child: Text(
                          isDone ? '✓' : '$stepNumber',
                          style: TextStyle(
                            color: isCurrent
                                ? Colors.white
                                : isDone
                                    ? _brandStrong
                                    : const Color(0xFF59677C),
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (index < 4)
                  Container(
                    width: 10,
                    height: 1,
                    color: const Color(0xFFDCE4F1),
                  ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildMainCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(17),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_step < 5) ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 19, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _stepNames[_step - 1],
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    _stepDescriptions[_step - 1],
                    style: const TextStyle(
                      color: _muted,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFFEBEFF5)),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
              child: _buildCurrentStepContent(),
            ),
            if (_validationMessage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                child: _buildValidationMessage(_validationMessage!),
              ),
            const Divider(height: 1, color: Color(0xFFEBEFF5)),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Step $_step of 5',
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (_step > 1) ...<Widget>[
                    OutlinedButton(
                      onPressed: _goBack,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _ink,
                        side: const BorderSide(color: _border),
                        minimumSize: const Size(74, 46),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(11),
                        ),
                      ),
                      child: const Text('Back'),
                    ),
                    const SizedBox(width: 8),
                  ],
                  FilledButton(
                    onPressed: _goNext,
                    style: FilledButton.styleFrom(
                      backgroundColor: _brand,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(112, 46),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(11),
                      ),
                    ),
                    child: Text(
                      _step == 4 ? 'Preview' : 'Continue →',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ),
          ] else
            _buildConfirmation(),
        ],
      ),
    );
  }

  Widget _buildCurrentStepContent() {
    switch (_step) {
      case 1:
        return _buildPropertyDetails();
      case 2:
        return _buildLocation();
      case 3:
        return _buildPhotos();
      case 4:
        return _buildReview();
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildPropertyDetails() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildTextField(
          label: 'Property name',
          controller: _nameController,
          requiredField: true,
          hint: 'Use a recognizable name for your property and dashboard.',
        ),
        const SizedBox(height: 17),
        _buildTextField(
          label: 'Monthly rental (MYR)',
          controller: _rentController,
          requiredField: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        const SizedBox(height: 17),
        _buildTextField(
          label: 'Built-up area (sq ft)',
          controller: _areaController,
          requiredField: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        const SizedBox(height: 19),
        const Divider(height: 1, color: Color(0xFFEEF1F5)),
        const SizedBox(height: 17),
        _buildChoiceGrid(),
        const SizedBox(height: 16),
        _buildInfoNotice(
          'Costs and area are used for affordability and size-based analysis. '
          'Production validation remains with your existing backend.',
        ),
      ],
    );
  }

  Widget _buildChoiceGrid() {
    const choices = <String>[
      'Shoplot',
      'Retail space',
      'Office',
      'Industrial',
      'Other',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _fieldLabel('Property type', requiredField: true),
        const SizedBox(height: 9),
        GridView.builder(
          itemCount: choices.length,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 9,
            crossAxisSpacing: 9,
            mainAxisExtent: 45,
          ),
          itemBuilder: (context, index) {
            final choice = choices[index];
            final selected = choice == _propertyType;
            return OutlinedButton(
              onPressed: () {
                setState(() {
                  _propertyType = choice;
                  _validationMessage = null;
                });
              },
              style: OutlinedButton.styleFrom(
                backgroundColor:
                    selected ? const Color(0xFFEEF5FF) : Colors.white,
                foregroundColor: selected ? _brandStrong : _muted,
                side: BorderSide(
                  color: selected
                      ? const Color(0xFF81A8FB)
                      : const Color(0xFFD6DEEA),
                  width: selected ? 1.5 : 1,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: Text(
                choice,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        const Text(
          'Choose the type supported by your existing listings catalogue.',
          style: TextStyle(color: _muted, fontSize: 11, height: 1.45),
        ),
      ],
    );
  }

  Widget _buildLocation() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildTextField(
          label: 'Street address',
          controller: _addressController,
          requiredField: true,
          hint: 'Street, building and unit number.',
        ),
        const SizedBox(height: 16),
        _buildTextField(
          label: 'State',
          controller: _stateController,
          requiredField: true,
        ),
        const SizedBox(height: 16),
        _buildTextField(
          label: 'District',
          controller: _districtController,
          requiredField: true,
        ),
        const SizedBox(height: 16),
        _buildTextField(
          label: 'Postcode',
          controller: _postcodeController,
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 16),
        _buildTextField(
          label: 'Latitude (optional)',
          controller: _latitudeController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        ),
        const SizedBox(height: 16),
        _buildTextField(
          label: 'Longitude (optional)',
          controller: _longitudeController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        ),
        const SizedBox(height: 15),
        _buildIllustrativeMap(),
      ],
    );
  }

  Widget _buildIllustrativeMap() {
    return Container(
      height: 175,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFFE8F0F3),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFFCEDBED)),
      ),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: CustomPaint(painter: _MapPatternPainter()),
          ),
          const Center(
            child: Icon(Icons.location_on, color: _brand, size: 38),
          ),
          Positioned(
            left: 10,
            right: 10,
            bottom: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.94),
                border: Border.all(color: const Color(0xFFD8E3F5)),
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Text(
                'Illustrative map only — connect your existing map integration.',
                style: TextStyle(
                  color: Color(0xFF34455E),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotos() {
    const photoLabels = <String>[
      'Exterior photo',
      'Interior photo',
      'Floor layout',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
          decoration: BoxDecoration(
            color: const Color(0xFFF7FAFF),
            border: Border.all(
              color: const Color(0xFFBBD0F3),
              width: 1.5,
              style: BorderStyle.solid,
            ),
            borderRadius: BorderRadius.circular(15),
          ),
          child: const Column(
            children: <Widget>[
              Icon(Icons.add_photo_alternate_outlined,
                  color: _brandStrong, size: 43),
              SizedBox(height: 12),
              Text(
                'Property photo gallery',
                style: TextStyle(
                  color: _ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              SizedBox(height: 7),
              Text(
                'This is a visual placeholder. The presentation preview does '
                'not read or upload local files.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted, fontSize: 11, height: 1.5),
              ),
              SizedBox(height: 12),
              Chip(
                label: Text('Optional step'),
                visualDensity: VisualDensity.compact,
                backgroundColor: Color(0xFFEDF4FF),
                side: BorderSide(color: Color(0xFFD4E3FB)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 15),
        GridView.builder(
          itemCount: photoLabels.length,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            mainAxisExtent: 98,
          ),
          itemBuilder: (context, index) {
            return Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: <Color>[Color(0xFFEDF3FB), Color(0xFFE1EBF7)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                border: Border.all(color: const Color(0xFFDCE6F3)),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const Icon(Icons.image_outlined,
                      color: Color(0xFF4D6380), size: 25),
                  const SizedBox(height: 6),
                  Text(
                    photoLabels[index],
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF4D6380),
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 14),
        _buildInfoNotice(
          'File type, size limits and photo upload must be handled by the '
          'existing media workflow.',
        ),
      ],
    );
  }

  Widget _buildReview() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildReviewSection(
          title: 'Property details',
          step: 1,
          rows: <_PreviewRow>[
            _PreviewRow('Property name', _display(_propertyName)),
            _PreviewRow('Property type', _propertyType),
            _PreviewRow('Monthly rent', 'RM $_monthlyRent'),
            _PreviewRow('Built-up area', '$_builtUpArea sq ft'),
          ],
        ),
        const SizedBox(height: 18),
        _buildReviewSection(
          title: 'Location & address',
          step: 2,
          rows: <_PreviewRow>[
            _PreviewRow('Address', _display(_address)),
            _PreviewRow('State', _display(_stateName)),
            _PreviewRow('District', _display(_district)),
            _PreviewRow('Postcode', _display(_postcode)),
            _PreviewRow(
              'Coordinates',
              _latitude.isEmpty ? 'Not provided' : '$_latitude, $_longitude',
            ),
          ],
        ),
        const SizedBox(height: 18),
        _buildReviewSection(
          title: 'Photos',
          step: 3,
          rows: const <_PreviewRow>[
            _PreviewRow('Upload status', 'Not connected in this preview'),
          ],
        ),
        const SizedBox(height: 16),
        _buildInfoNotice(
          'This preview does not send an API request or create a property record.',
        ),
      ],
    );
  }

  Widget _buildReviewSection({
    required String title,
    required int step,
    required List<_PreviewRow> rows,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            TextButton(
              onPressed: () => _editStep(step),
              child: const Text(
                'Edit',
                style: TextStyle(
                  color: _brandStrong,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const Divider(height: 1, color: Color(0xFFE9EDF4)),
        const SizedBox(height: 9),
        ...rows.map(_buildPreviewRow),
      ],
    );
  }

  Widget _buildConfirmation() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 28, 18, 24),
      child: Column(
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF3D8),
              border: Border.all(color: const Color(0xFFFFE3AB)),
              borderRadius: BorderRadius.circular(30),
            ),
            child: const Text(
              'UI preview — not saved',
              style: TextStyle(
                color: Color(0xFF965410),
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 18),
          Container(
            width: 66,
            height: 66,
            decoration: const BoxDecoration(
              color: Color(0xFFDDF8E9),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_rounded,
                color: Color(0xFF087443), size: 39),
          ),
          const SizedBox(height: 17),
          const Text(
            'Submission confirmation design',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _ink,
              fontSize: 19,
              fontWeight: FontWeight.w900,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 9),
          const Text(
            'This is how the creation-success state could appear after the '
            'real FastAPI Add Property use case returns a property ID.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _muted, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 19),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: _border),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'Sample property',
                  style: TextStyle(
                    color: _muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _display(_propertyName),
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 13),
                  child: Divider(height: 1, color: Color(0xFFEEF1F5)),
                ),
                const Text(
                  'Property ID',
                  style: TextStyle(
                    color: _muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Assigned by backend after successful creation',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => _editStep(1),
              style: FilledButton.styleFrom(
                backgroundColor: _brand,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(47),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(11),
                ),
              ),
              child: const Text(
                'Review the design again',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
          const SizedBox(height: 9),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => _editStep(1),
              style: OutlinedButton.styleFrom(
                foregroundColor: _ink,
                side: const BorderSide(color: _border),
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(11),
                ),
              ),
              child: const Text(
                'Go to My Properties (preview)',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPropertySnapshot() {
    final rows = <_PreviewRow>[
      _PreviewRow('Property name', _display(_propertyName)),
      _PreviewRow('Property type', _propertyType),
      _PreviewRow('Monthly rental', 'RM ${_monthlyRent.isEmpty ? '—' : _monthlyRent}'),
      _PreviewRow('Built-up area', _builtUpArea.isEmpty ? '—' : '$_builtUpArea sq ft'),
      _PreviewRow('State', _display(_stateName)),
      _PreviewRow('District', _display(_district)),
      const _PreviewRow('Media', 'Connected in production only'),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(17, 18, 17, 15),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(17),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text(
            'PROPERTY SNAPSHOT',
            style: TextStyle(
              color: _brandStrong,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: 3),
          const Text(
            'Your draft at a glance',
            style: TextStyle(
              color: _ink,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'This summary updates as you enter your property information.',
            style: TextStyle(color: _muted, fontSize: 12, height: 1.45),
          ),
          const SizedBox(height: 12),
          ...rows.map(_buildSnapshotRow),
        ],
      ),
    );
  }

  Widget _buildSnapshotRow(_PreviewRow row) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFEEF1F5))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Text(
              row.label,
              style: const TextStyle(
                color: _muted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              row.value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Color(0xFF1C2940),
                fontSize: 11,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWorkflowNote() {
    return Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F6FF),
        border: Border.all(color: const Color(0xFFD6E5FF)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Built for your SiteWise workflow',
            style: TextStyle(
              color: Color(0xFF163C8D),
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(height: 7),
          Text(
            'White navigation, the existing blue palette, accessible form '
            'layout and the entrepreneur workspace. This is a standalone '
            'design demonstration, not an API implementation.',
            style: TextStyle(
              color: Color(0xFF284B83),
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    bool requiredField = false,
    TextInputType? keyboardType,
    String? hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _fieldLabel(label, requiredField: requiredField),
        const SizedBox(height: 7),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          onChanged: _onTextChanged,
          style: const TextStyle(color: _ink, fontSize: 13),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFFFAFBFD),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide: const BorderSide(color: Color(0xFFD5DDE9)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide: const BorderSide(color: Color(0xFFD5DDE9)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide: const BorderSide(color: _brand, width: 1.5),
            ),
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF7A8798), fontSize: 12),
          ),
        ),
        if (hint != null && keyboardType == null && !requiredField) ...<Widget>[
          const SizedBox(height: 5),
          Text(
            hint,
            style: const TextStyle(color: _muted, fontSize: 10, height: 1.4),
          ),
        ],
      ],
    );
  }

  Widget _fieldLabel(String text, {bool requiredField = false}) {
    return RichText(
      text: TextSpan(
        style: const TextStyle(
          color: Color(0xFF1C2637),
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
        children: <InlineSpan>[
          TextSpan(text: text),
          if (requiredField)
            const TextSpan(
              text: ' *',
              style: TextStyle(color: Color(0xFFB91C1C)),
            ),
        ],
      ),
    );
  }

  Widget _buildInfoNotice(String message) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F7FF),
        border: Border.all(color: const Color(0xFFD6E5FB)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.info_outline_rounded,
              color: Color(0xFF245FCF), size: 17),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Color(0xFF21477F),
                fontSize: 11,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildValidationMessage(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF0F0),
        border: Border.all(color: const Color(0xFFF1B8B8)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        message,
        style: const TextStyle(
          color: Color(0xFF991B1B),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildPreviewRow(_PreviewRow row) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            row.label,
            style: const TextStyle(
              color: Color(0xFF627088),
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            row.value,
            style: const TextStyle(
              color: Color(0xFF1A273A),
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewRow {
  const _PreviewRow(this.label, this.value);

  final String label;
  final String value;
}

class _MapPatternPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final roadPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.88)
      ..strokeWidth = 8
      ..style = PaintingStyle.stroke;

    final thinRoadPaint = Paint()
      ..color = const Color(0xFFD4E0E9)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    final roads = <Path>[
      Path()
        ..moveTo(-10, size.height * 0.22)
        ..cubicTo(size.width * 0.25, size.height * 0.08,
            size.width * 0.55, size.height * 0.34, size.width + 10, size.height * 0.18),
      Path()
        ..moveTo(-10, size.height * 0.75)
        ..cubicTo(size.width * 0.30, size.height * 0.55,
            size.width * 0.66, size.height * 0.92, size.width + 10, size.height * 0.66),
      Path()
        ..moveTo(size.width * 0.25, -10)
        ..cubicTo(size.width * 0.12, size.height * 0.35,
            size.width * 0.43, size.height * 0.62, size.width * 0.30, size.height + 10),
      Path()
        ..moveTo(size.width * 0.76, -10)
        ..cubicTo(size.width * 0.60, size.height * 0.30,
            size.width * 0.94, size.height * 0.70, size.width * 0.78, size.height + 10),
    ];

    for (final path in roads) {
      canvas.drawPath(path, roadPaint);
      canvas.drawPath(path, thinRoadPaint);
    }

    final blockPaint = Paint()
      ..color = const Color(0xFFDCE8E1).withValues(alpha: 0.65)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * 0.42, size.height * 0.13, 42, 22),
        const Radius.circular(4),
      ),
      blockPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * 0.08, size.height * 0.48, 34, 19),
        const Radius.circular(4),
      ),
      blockPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
