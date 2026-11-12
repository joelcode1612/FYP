import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/config/mobile_config.dart';
import '../../../../core/utils/capture_log.dart';
import '../../shell/entrepreneur_tab_scope.dart';
import '../../shell/mobile_app_shell.dart';
import '../../../shared/tour/ar_capture_mobile_page.dart';

/// SiteWise Add Property — REAL owner-listing workflow.
///
/// Drafts persist in PostgreSQL (`fyp.rental_properties` with
/// ``verification_status='draft'``) through the authenticated FastAPI
/// endpoints; submitting hands the record to the existing property
/// verification workflow (documents -> submit -> admin review). There is no
/// local-only state here: every save is a server round trip, and the
/// confirmation step shows the real database-assigned property ID.
class SitewiseAddPropertyMobilePage extends StatefulWidget {
  /// Resume an existing draft (`fyp.rental_properties.id`) from
  /// My Properties. Null starts a blank form.
  final String? initialDraftId;

  const SitewiseAddPropertyMobilePage({super.key, this.initialDraftId});

  @override
  State<SitewiseAddPropertyMobilePage> createState() =>
      _SitewiseAddPropertyMobilePageState();
}

class _SitewiseAddPropertyMobilePageState
    extends State<SitewiseAddPropertyMobilePage> {
  static const Color _brand = Color(0xFF2F6FED);
  static const Color _brandStrong = Color(0xFF1D4ED8);
  static const Color _background = Color(0xFFF6F7F9);
  static const Color _ink = Color(0xFF10151F);
  static const Color _muted = Color(0xFF58677D);
  static const Color _border = Color(0xFFE2E8F0);
  static const Color _errorInk = Color(0xFFB42318);
  static const Color _errorBorder = Color(0xFFE7A6A0);

  static const List<String> _stepNames = <String>[
    'Property details',
    'Location',
    'AR 360° Capture',
    'Review',
    'Confirmation',
  ];

  static const List<String> _stepDescriptions = <String>[
    'Enter the basic details of your commercial unit.',
    'Add the address details of your commercial unit.',
    'Capture a 360° virtual tour of the property with AR guidance.',
    'Review the information before submission.',
    'Save or submit your property.',
  ];

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _rentController = TextEditingController();
  final TextEditingController _areaController = TextEditingController();
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _stateController = TextEditingController();
  final TextEditingController _districtController = TextEditingController();
  final TextEditingController _postcodeController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();

  int _step = 1;
  String _propertyType = 'Shoplot';
  String? _validationMessage;

  /// Field-specific errors, rendered under the relevant control. The shared
  /// [PropertyFormRules] produce the messages so web and mobile agree.
  final Map<String, String> _fieldErrors = <String, String>{};

  // Server state: the persisted PostgreSQL draft and its lifecycle.
  String? _draftId;
  String _serverStatus = 'draft';
  String? _rejectionReason;
  bool _saving = false;
  bool _submitting = false;
  String? _serverMessage;
  String? _serverError;

  /// The unfinished 360° capture for this property, when one exists.
  ///
  /// Only a draft tour that already holds confirmed frames is resumable. A
  /// draft with zero frames is an empty session, so offering "Resume" for it
  /// would promise progress that was never made.
  String? _resumableTourId;

  String get _propertyName => _nameController.text.trim();
  String get _monthlyRent => _rentController.text.trim();
  String get _builtUpArea => _areaController.text.trim();
  String get _address => _addressController.text.trim();
  String get _stateName => _stateController.text.trim();
  String get _district => _districtController.text.trim();
  String get _postcode => _postcodeController.text.trim();

  /// The record can only be edited while the backend policy allows it
  /// (draft, rejected or corrections-requested). The backend enforces the
  /// same rule; this only disables the UI honestly.
  bool get _editable =>
      _draftId == null || _serverStatus == 'draft' || _serverStatus == 'rejected';

  bool get _live => MobileConfig.usesLiveApi;

  @override
  void initState() {
    super.initState();
    if (widget.initialDraftId != null &&
        widget.initialDraftId!.isNotEmpty &&
        MobileConfig.usesLiveApi) {
      _resumeDraft(widget.initialDraftId!);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _rentController.dispose();
    _areaController.dispose();
    _addressController.dispose();
    _stateController.dispose();
    _districtController.dispose();
    _postcodeController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Server lifecycle
  // ---------------------------------------------------------------------------

  Future<void> _resumeDraft(String id) async {
    setState(() {
      _saving = true;
      _serverError = null;
    });
    try {
      final listing = await ServiceLocator.ownerListings.getListing(id);
      if (!mounted) return;
      _applyListing(listing);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _serverError = _readableError(error, fallback: 'Could not load the saved draft.');
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _applyListing(OwnerListing listing) {
    _draftId = listing.id;
    _serverStatus = listing.verificationStatus;
    _rejectionReason = listing.rejectionReason;
    String text(TextEditingController c, String? v) {
      c.text = v ?? '';
      return c.text;
    }

    text(_nameController, listing.name);
    text(_rentController,
        listing.rentalPrice == null ? '' : listing.rentalPrice!.toStringAsFixed(0));
    text(_areaController,
        listing.sizeSqft == null ? '' : listing.sizeSqft!.toStringAsFixed(0));
    text(_addressController, listing.address);
    text(_stateController, listing.state);
    text(_districtController, listing.city);
    text(_postcodeController, listing.postcode);
    text(_descriptionController, listing.description);
    final normalizedType = normalizeCommercialPropertyType(listing.propertyType);
    if (normalizedType != null) _propertyType = normalizedType;
    setState(() {});
  }

  void _onStateChanged(String? value) {
    setState(() {
      _stateController.text = value ?? '';
      _districtController.clear();
      _postcodeController.clear();
      _fieldErrors.remove('state');
      _fieldErrors.remove('city');
      _fieldErrors.remove('postcode');
      _validationMessage = null;
    });
  }

  void _onCityChanged(String? value) {
    setState(() {
      _districtController.text = value ?? '';
      _postcodeController.clear();
      _fieldErrors.remove('city');
      _fieldErrors.remove('postcode');
      _validationMessage = null;
    });
  }

  void _onPostcodeChanged(String? value) {
    setState(() {
      _postcodeController.text = value ?? '';
      _fieldErrors.remove('postcode');
      _validationMessage = null;
    });
  }

  Map<String, dynamic> _draftFields() => OwnerListing(
        id: _draftId ?? '',
        name: '',
        verificationStatus: _serverStatus,
      ).toDraftJson(
        name: _propertyName.isEmpty ? null : _propertyName,
        propertyType: _propertyType,
        description:
            _descriptionController.text.trim().isEmpty ? null : _descriptionController.text.trim(),
        address: _address.isEmpty ? null : _address,
        city: _district.isEmpty ? null : _district,
        state: _stateName.isEmpty ? null : _stateName,
        postcode: _postcode.isEmpty ? null : _postcode,
        rentalPrice: double.tryParse(_monthlyRent),
        sizeSqft: double.tryParse(_builtUpArea),
        availability: _serverStatus == 'draft' ? null : 'Immediate',
        hasParking: false,
        isFnbSuitable: false,
      );

  /// Save Draft: create the row once, then update the SAME row. The backend
  /// stamps the owner from the verified token and assigns the persistent id.
  Future<void> _saveDraft() async {
    if (_saving) return; // double-tap guard
    if (!_live) {
      setState(() {
        _serverError =
            'Draft saving requires the live Sitewise service '
            '(a demo build keeps no property records).';
      });
      return;
    }
    setState(() {
      _saving = true;
      _serverError = null;
      _serverMessage = null;
      _validationMessage = null;
    });
    try {
      final repository = ServiceLocator.ownerListings;
      final OwnerListing saved;
      if (_draftId == null) {
        saved = await repository.createDraft(_draftFields());
      } else {
        saved = await repository.updateDraft(_draftId!, _draftFields());
      }
      if (!mounted) return;
      setState(() {
        _draftId = saved.id;
        _serverStatus = saved.verificationStatus;
        _serverMessage = 'Draft saved to Sitewise (ID ${saved.id}). '
            'You can leave this page and resume it later from My Properties.';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _serverError = _readableError(error, fallback: 'Could not save the draft.');
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Submit for Verification: a distinct action from Save Draft. The backend
  /// validates completeness, requires ownership evidence, moves the record
  /// into the admin queue atomically and returns the pending status.
  Future<void> _submitForVerification() async {
    if (_submitting) return; // repeated taps cannot create multiple submissions
    if (!_live) {
      setState(() {
        _serverError =
            'Submission requires the live Sitewise service '
            '(a demo build keeps no property records).';
      });
      return;
    }
    setState(() {
      _submitting = true;
      _serverError = null;
      _serverMessage = null;
    });
    try {
      // The record must exist before evidence can attach to it.
      String id = _draftId ?? '';
      if (id.isEmpty) {
        final saved = await ServiceLocator.ownerListings.createDraft(_draftFields());
        if (!mounted) return;
        id = saved.id;
        _draftId = id;
        _serverStatus = saved.verificationStatus;
      } else {
        await ServiceLocator.ownerListings.updateDraft(id, _draftFields());
      }
      final result = await ServiceLocator.propertyVerification.submit(id);
      if (!mounted) return;
      // The verification status changed on the server. The draft update above
      // already bumped the listings revision, but that happened BEFORE this
      // call returned — bump again so My Properties refetches the record with
      // its new "pending review" status instead of the "draft" it just read.
      ServiceLocator.listingsRevision.value++;
      setState(() {
        _serverStatus = 'pending';
        _serverMessage = 'Submitted for verification (ID $id). '
            'Status: ${result.listingStatus.wire}/${result.ownershipStatus.wire}. '
            'An administrator will review your listing and ownership evidence.';
        _step = 5;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _serverError = _readableError(
          error,
          fallback: 'Submission could not proceed. Your draft is saved.',
        );
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _readableError(Object error, {required String fallback}) {
    if (error is AppFailure) return error.message;
    return fallback;
  }

  // ---------------------------------------------------------------------------
  // Step validation + navigation (client-side guard only; the backend is
  // authoritative at submission time)
  // ---------------------------------------------------------------------------

  String _display(String value) => value.isEmpty ? 'Not provided' : value;

  bool _validateCurrentStep() {
    _fieldErrors.clear();
    if (!_editable) {
      _validationMessage =
          'This record is awaiting review — its details can no longer be edited.';
      return false;
    }
    if (_step == 1) _collectDetailsErrors();
    if (_step == 2) _collectLocationErrors();
    if (_step == 4) {
      // Review re-checks everything: navigating back and clearing a field must
      // not let an incomplete draft reach the confirmation step.
      _collectDetailsErrors();
      _collectLocationErrors();
    }
    if (_fieldErrors.isNotEmpty) {
      _validationMessage = 'Please correct the highlighted information.';
      return false;
    }
    _validationMessage = null;
    return true;
  }

  void _collectDetailsErrors() {
    _putField('title', PropertyFormRules.titleError(_propertyName));
    _putField('type', PropertyFormRules.propertyTypeError(_propertyType));
    _putField('rent', PropertyFormRules.rentError(_monthlyRent));
    _putField('area', PropertyFormRules.areaError(_builtUpArea));
  }

  void _collectLocationErrors() {
    _putField('address', PropertyFormRules.addressError(_address));
    _putField('state', PropertyFormRules.stateError(_stateName));
    _putField('city', PropertyFormRules.cityError(_stateName, _district));
    _putField(
      'postcode',
      PropertyFormRules.postcodeError(
        _postcode,
        state: _stateName,
        city: _district,
      ),
    );
  }

  void _putField(String key, String? message) {
    if (message != null) _fieldErrors[key] = message;
  }

  void _goNext() {
    if (_step >= 5) return;
    setState(() {
      if (_validateCurrentStep()) {
        _step += 1;
        _validationMessage = null;
        if (_step == 5 && _live) {
          // Reaching the confirmation step autosaves so the record exists
          // even if the user leaves before pressing either button.
          _saveDraft();
        }
      }
    });
    // Entering Step 3 decides whether "Resume Previous Capture" may be shown,
    // so the lookup runs for the footer path as well as the stepper.
    if (_step == 3) unawaited(_refreshResumable());
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
    // Step 3 is the only step whose actions depend on persisted state: whether
    // an interrupted capture exists decides if "Resume" may be shown at all.
    if (step == 3) unawaited(_refreshResumable());
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
        // The Add Property flow is entered from the Spaces tab, so the header
        // keeps no back arrow — the tab dock is the way back.
        showBack: false,
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
                        const SizedBox(height: 8),
                        _buildPageHeading(),
                        const SizedBox(height: 18),
                        _buildStepper(),
                        const SizedBox(height: 18),
                        _buildMainCard(),
                        if (_serverMessage != null) ...<Widget>[
                          const SizedBox(height: 14),
                          _buildServerBanner(_serverMessage!, success: true),
                        ],
                        if (_serverError != null) ...<Widget>[
                          const SizedBox(height: 14),
                          _buildServerBanner(_serverError!, success: false),
                        ],
                        if (_rejectionReason != null &&
                            _serverStatus == 'rejected') ...<Widget>[
                          const SizedBox(height: 14),
                          _buildServerBanner(
                            'Administrator requested corrections: $_rejectionReason',
                            success: false,
                          ),
                        ],
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
        Text(
          _draftId == null
              ? 'Create a real property record, save it as a draft and submit '
                    'it for administrator verification.'
              : 'Editing saved property #$_draftId (status: $_serverStatus).',
          style: const TextStyle(color: _muted, fontSize: 13, height: 1.5),
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
                  // Flexible keeps the narrow-phone footer overflow-free:
                  // the label may shrink/ellipsize instead of pushing the
                  // row past the 390dp viewport.
                  Flexible(
                    child: FilledButton(
                      onPressed: _saving ? null : _goNext,
                      style: FilledButton.styleFrom(
                        backgroundColor: _brand,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 46),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(11),
                        ),
                      ),
                      child: Text(
                        _step == 4 ? 'Review & finish' : 'Continue →',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
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
        return _buildArCapture();
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
          label: 'Property title',
          controller: _nameController,
          requiredField: true,
          hint: 'e.g. Ground Floor Corner Shoplot at SS15',
          error: _fieldErrors['title'],
        ),
        const SizedBox(height: 17),
        _buildTextField(
          label: 'Monthly rental (MYR)',
          controller: _rentController,
          requiredField: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          error: _fieldErrors['rent'],
        ),
        const SizedBox(height: 17),
        _buildTextField(
          label: 'Built-up area (sq ft)',
          controller: _areaController,
          requiredField: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          error: _fieldErrors['area'],
        ),
        const SizedBox(height: 17),
        _buildTextField(
          label: 'Description (optional)',
          controller: _descriptionController,
          hint: 'Condition, frontage, power supply, tenancy notes.',
        ),
        const SizedBox(height: 19),
        const Divider(height: 1, color: Color(0xFFEEF1F5)),
        const SizedBox(height: 17),
        _buildChoiceGrid(),
        const SizedBox(height: 16),
        _buildInfoNotice(
          'Saving creates a real draft record in Sitewise. Submitting sends '
          'it to administrator verification — approval is never automatic.',
        ),
      ],
    );
  }

  Widget _buildChoiceGrid() {
    final choices = commercialPropertyTypeLabels;
    final error = _fieldErrors['type'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _fieldLabel('Commercial property type', requiredField: true),
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
                  _fieldErrors.remove('type');
                  _validationMessage = null;
                });
              },
              style: OutlinedButton.styleFrom(
                backgroundColor: selected
                    ? const Color(0xFFEEF5FF)
                    : Colors.white,
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
        if (error != null) ...<Widget>[
          const SizedBox(height: 7),
          _buildFieldError(error),
        ],
      ],
    );
  }

  Widget _buildLocation() {
    final cityOptions = MalaysiaLocations.citiesFor(_stateName);
    final postcodeOptions = MalaysiaLocations.postcodesFor(
      _stateName,
      _district,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildTextField(
          label: 'Street address',
          controller: _addressController,
          requiredField: true,
          hint: 'Building name, unit number and street.',
          helper:
              'Include the unit or lot number — Google checks the address '
              'exactly as written.',
          error: _fieldErrors['address'],
          onChanged: _onAddressChanged,
        ),
        const SizedBox(height: 16),
        _buildSelectField(
          label: 'State / federal territory',
          value: _stateName,
          hint: 'Select a state',
          options: MalaysiaLocations.stateNames,
          searchable: true,
          requiredField: true,
          error: _fieldErrors['state'],
          onSelected: _onStateChanged,
        ),
        const SizedBox(height: 16),
        _buildSelectField(
          label: 'City / township',
          value: _district,
          hint: _stateName.isEmpty
              ? 'Select a state first'
              : 'Search cities in $_stateName',
          options: cityOptions,
          enabled: _stateName.isNotEmpty,
          requiredField: true,
          error: _fieldErrors['city'],
          onSelected: _onCityChanged,
        ),
        const SizedBox(height: 16),
        _buildSelectField(
          label: 'Postcode',
          value: _postcode,
          hint: _district.isEmpty
              ? 'Select a city first'
              : 'Search postcodes for $_district',
          options: postcodeOptions,
          enabled: _district.isNotEmpty,
          requiredField: true,
          helper: postcodeOptions.isEmpty
              ? null
              : '${postcodeOptions.length} postcode(s) listed for this city.',
          error: _fieldErrors['postcode'],
          onSelected: _onPostcodeChanged,
        ),
        const SizedBox(height: 18),
        _buildInfoNotice(
          'SiteWise administrators separately verify the listing and '
          'ownership evidence after submission. Ownership evidence is '
          'uploaded separately from My Properties.',
        ),
      ],
    );
  }

  void _onAddressChanged(String value) {
    setState(() {
      _fieldErrors.remove('address');
      _validationMessage = null;
    });
  }

  /// A tappable field that opens a searchable option sheet.
  ///
  /// Used for the dependent State -> City -> Postcode chain: the option list is
  /// always the dataset list for the current parent selection, so an
  /// incompatible value can never be entered in the first place.
  Widget _buildSelectField({
    required String label,
    required String value,
    required String hint,
    required List<String> options,
    required ValueChanged<String> onSelected,
    bool requiredField = false,
    bool enabled = true,
    bool searchable = true,
    String? helper,
    String? error,
  }) {
    final hasValue = value.isNotEmpty;
    final canOpen = _editable && enabled && options.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _fieldLabel(label, requiredField: requiredField),
        const SizedBox(height: 7),
        InkWell(
          onTap: canOpen
              ? () => _openOptionPicker(
                  title: label,
                  options: options,
                  selected: value,
                  onSelected: onSelected,
                )
              : null,
          borderRadius: BorderRadius.circular(11),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            decoration: BoxDecoration(
              color: canOpen
                  ? const Color(0xFFFAFBFD)
                  : const Color(0xFFF2F4F7),
              border: Border.all(
                color: error == null ? const Color(0xFFD5DDE9) : _errorBorder,
              ),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    hasValue ? value : hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: hasValue ? _ink : const Color(0xFF7A8798),
                      fontSize: hasValue ? 13 : 12,
                      fontWeight: hasValue ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ),
                Icon(
                  searchable ? Icons.search_rounded : Icons.expand_more_rounded,
                  size: 17,
                  color: canOpen ? _muted : const Color(0xFFA9B4C2),
                ),
              ],
            ),
          ),
        ),
        if (helper != null && error == null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            helper,
            style: const TextStyle(
              color: Color(0xFF6B7A90),
              fontSize: 10,
              height: 1.45,
            ),
          ),
        ],
        if (error != null) ...<Widget>[
          const SizedBox(height: 6),
          _buildFieldError(error),
        ],
      ],
    );
  }

  Future<void> _openOptionPicker({
    required String title,
    required List<String> options,
    required String selected,
    required ValueChanged<String> onSelected,
  }) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) =>
          _OptionSheet(title: title, options: options, selected: selected),
    );
    if (!mounted || picked == null) return;
    onSelected(picked);
  }

  // ------------------------------------------------------- AR 360 capture
  bool _startingCapture = false;

  /// Looks for an interrupted capture belonging to the saved draft.
  ///
  /// The query is the tour service's property-scoped draft lookup, so it can
  /// only ever answer with a draft/processing tour — never with a finished one.
  /// The frame count comes from the tour record, which the capture screen keeps
  /// in step with the JPEGs actually written.
  Future<void> _refreshResumable() async {
    final id = _draftId;
    if (id == null || id.isEmpty) {
      if (mounted && _resumableTourId != null) {
        setState(() => _resumableTourId = null);
      }
      return;
    }
    try {
      final tour = await ServiceLocator.tourService.tourForPropertyDraft(id);
      final resumable = tour != null && tour.frameCount > 0 ? tour.id : null;
      if (!mounted || resumable == _resumableTourId) return;
      setState(() => _resumableTourId = resumable);
    } catch (error) {
      CaptureLog.log('Resumable capture lookup failed: $error');
    }
  }

  Future<void> _startArCapture() async {
    if (_startingCapture) return;
    setState(() => _startingCapture = true);
    try {
      await _saveDraft();
      final id = _draftId;
      if (!mounted) return;
      if (id == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The draft could not be saved, so AR capture was not started.',
            ),
          ),
        );
        return;
      }
      await Navigator.of(context).pushNamed(
        '/owner/capture',
        arguments: ArCaptureRequest(propertyId: id),
      );
      if (mounted) {
        setState(() {});
        await _refreshResumable();
      }
    } finally {
      if (mounted) setState(() => _startingCapture = false);
    }
  }

  Widget _arGuidance(IconData icon, String title, String body) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArCapture() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.view_in_ar_outlined, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'AR 360° Capture',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _arGuidance(
                Icons.grid_on_outlined,
                'Follow 26 capture points',
                'Stand in one spot and turn your body slowly in a full '
                    'circle. Hold steady at each point; ARCore records the '
                    'direction when it is aligned and stable.',
              ),
              _arGuidance(
                Icons.center_focus_strong_outlined,
                'AR alignment guidance',
                'Align the target, hold still, and let the app confirm the '
                    'position before the frame is taken.',
              ),
              _arGuidance(
                Icons.panorama_outlined,
                'Create a virtual tour',
                'Frames are stitched into a 360° tour for this property.',
              ),
              const SizedBox(height: 4),
              FilledButton.icon(
                onPressed: _startingCapture ? null : _startArCapture,
                icon: const Icon(Icons.play_circle_outline),
                label: Text(
                  _startingCapture ? 'Saving draft…' : 'Start AR Capture',
                ),
              ),
              // Only ever rendered for a real interrupted capture: the lookup
              // returns draft tours that already hold frames, so this cannot
              // promise progress that was not saved.
              if (_resumableTourId != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _startingCapture ? null : _startArCapture,
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Resume Previous Capture'),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'The virtual tour will be linked to this property and can be '
                'reviewed in My Properties.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
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
          rows: <_ReviewRow>[
            _ReviewRow('Property title', _display(_propertyName)),
            _ReviewRow('Commercial property type', _propertyType),
            _ReviewRow('Monthly rental', 'RM $_monthlyRent'),
            _ReviewRow('Built-up area', '$_builtUpArea sq ft'),
          ],
        ),
        const SizedBox(height: 18),
        _buildReviewSection(
          title: 'Location & address',
          step: 2,
          rows: <_ReviewRow>[
            _ReviewRow('Street address', _display(_address)),
            _ReviewRow('State', _display(_stateName)),
            _ReviewRow('City / township', _display(_district)),
            _ReviewRow('Postcode', _display(_postcode)),
          ],
        ),
        const SizedBox(height: 16),
        _buildInfoNotice(
          'Review & finish saves the record to Sitewise. Submission for '
          'verification additionally requires complete details and, for full '
          'verification, at least one ownership document.',
        ),
      ],
    );
  }

  Widget _buildReviewSection({
    required String title,
    required int step,
    required List<_ReviewRow> rows,
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
        ...rows.map(_buildReviewRow),
      ],
    );
  }

  Widget _buildConfirmation() {
    final submitted = _serverStatus == 'pending';
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 28, 18, 24),
      child: Column(
        children: <Widget>[
          Container(
            width: 66,
            height: 66,
            decoration: BoxDecoration(
              color: submitted
                  ? const Color(0xFFDDF8E9)
                  : const Color(0xFFEDF4FF),
              shape: BoxShape.circle,
            ),
            child: Icon(
              submitted ? Icons.check_rounded : Icons.save_rounded,
              color: submitted ? const Color(0xFF087443) : _brandStrong,
              size: 39,
            ),
          ),
          const SizedBox(height: 17),
          Text(
            submitted ? 'Submitted for verification' : 'Draft saved',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _ink,
              fontSize: 19,
              fontWeight: FontWeight.w900,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 9),
          Text(
            submitted
                ? 'Your property is now in the administrator review queue. '
                      'Track its status in My Properties.'
                : 'This property record is persisted in Sitewise. Complete the '
                      'details and attach ownership evidence, then '
                      'submit it for verification.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted, fontSize: 12, height: 1.5),
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
                  'Property',
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
                Text(
                  _draftId ?? 'Not saved yet',
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (!submitted) ...<Widget>[
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _submitting ? null : _submitForVerification,
                icon: _submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.verified_outlined, size: 19),
                label: Text(
                  _submitting ? 'Submitting…' : 'Submit for verification',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: _brand,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(47),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 9),
          ],
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _saving
                  ? null
                  : () {
                      _saveDraft();
                    },
              style: OutlinedButton.styleFrom(
                foregroundColor: _ink,
                side: const BorderSide(color: _border),
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(11),
                ),
              ),
              child: Text(
                _saving ? 'Saving…' : 'Save draft',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
          const SizedBox(height: 9),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () =>
                  EntrepreneurTabScope.open(context, '/entrepreneur/spaces'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _ink,
                side: const BorderSide(color: _border),
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(11),
                ),
              ),
              child: const Text(
                'Go to My Properties',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildServerBanner(String message, {required bool success}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: success ? const Color(0xFFEAF8F0) : const Color(0xFFFFF0F0),
        border: Border.all(
          color: success ? const Color(0xFFB4E4CB) : const Color(0xFFF1B8B8),
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            success
                ? Icons.check_circle_outline_rounded
                : Icons.error_outline_rounded,
            color: success ? const Color(0xFF087443) : const Color(0xFF991B1B),
            size: 17,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: success
                    ? const Color(0xFF0A5B36)
                    : const Color(0xFF991B1B),
                fontSize: 11,
                height: 1.5,
                fontWeight: FontWeight.w700,
              ),
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
    String? helper,
    String? error,
    int maxLines = 1,
    ValueChanged<String>? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _fieldLabel(label, requiredField: requiredField),
        const SizedBox(height: 7),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          maxLines: maxLines,
          enabled: _editable,
          onChanged: onChanged ?? _onTextChanged,
          style: const TextStyle(color: _ink, fontSize: 13),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFFFAFBFD),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide: BorderSide(
                color: error == null ? const Color(0xFFD5DDE9) : _errorBorder,
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide: BorderSide(
                color: error == null ? const Color(0xFFD5DDE9) : _errorBorder,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide: BorderSide(
                color: error == null ? _brand : _errorBorder,
                width: 1.5,
              ),
            ),
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF7A8798), fontSize: 12),
          ),
        ),
        if (helper != null && error == null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            helper,
            style: const TextStyle(
              color: Color(0xFF6B7A90),
              fontSize: 10,
              height: 1.45,
            ),
          ),
        ],
        if (error != null) ...<Widget>[
          const SizedBox(height: 6),
          _buildFieldError(error),
        ],
      ],
    );
  }

  Widget _buildFieldError(String message) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Icon(Icons.error_outline_rounded, color: _errorInk, size: 13),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(
              color: _errorInk,
              fontSize: 10,
              height: 1.45,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
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
          const Icon(
            Icons.info_outline_rounded,
            color: Color(0xFF245FCF),
            size: 17,
          ),
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

  Widget _buildReviewRow(_ReviewRow row) {
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

class _ReviewRow {
  const _ReviewRow(this.label, this.value);

  final String label;
  final String value;
}

/// Searchable single-select sheet used by the State / City / Postcode fields.
///
/// The list always comes from the Malaysian postcode dataset in Shared Logic,
/// so the owner can only pick a value that actually exists for the parent
/// selection — the free-text path that produced mismatched state/postcode pairs
/// is gone.
class _OptionSheet extends StatefulWidget {
  const _OptionSheet({
    required this.title,
    required this.options,
    required this.selected,
  });

  final String title;
  final List<String> options;
  final String selected;

  @override
  State<_OptionSheet> createState() => _OptionSheetState();
}

class _OptionSheetState extends State<_OptionSheet> {
  static const Color _ink = Color(0xFF10151F);
  static const Color _muted = Color(0xFF58677D);
  static const Color _brand = Color(0xFF2F6FED);

  final TextEditingController _filter = TextEditingController();
  List<String> _visible = const <String>[];

  @override
  void initState() {
    super.initState();
    _visible = widget.options;
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _applyFilter(String query) {
    final needle = query.trim().toLowerCase();
    setState(() {
      _visible = needle.isEmpty
          ? widget.options
          : widget.options
                .where((option) => option.toLowerCase().contains(needle))
                .toList(growable: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.68;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SizedBox(height: 9),
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD8DFE9),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
                child: Text(
                  widget.title,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 6, 18, 8),
                child: TextField(
                  controller: _filter,
                  autofocus: false,
                  onChanged: _applyFilter,
                  style: const TextStyle(color: _ink, fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: const Color(0xFFF6F8FC),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: _muted,
                    ),
                    hintText: 'Search ${widget.title.toLowerCase()}',
                    hintStyle: const TextStyle(
                      color: Color(0xFF7A8798),
                      fontSize: 12,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFFD5DDE9)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFFD5DDE9)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: _brand, width: 1.5),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _visible.isEmpty
                    ? Center(
                        child: Text(
                          'No match for "${_filter.text.trim()}"',
                          style: const TextStyle(color: _muted, fontSize: 12),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _visible.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1, color: Color(0xFFEFF2F7)),
                        itemBuilder: (context, index) {
                          final option = _visible[index];
                          final selected = option == widget.selected;
                          return ListTile(
                            dense: true,
                            title: Text(
                              option,
                              style: TextStyle(
                                color: selected ? _brand : _ink,
                                fontSize: 13,
                                fontWeight: selected
                                    ? FontWeight.w800
                                    : FontWeight.w500,
                              ),
                            ),
                            trailing: selected
                                ? const Icon(
                                    Icons.check_rounded,
                                    size: 18,
                                    color: _brand,
                                  )
                                : null,
                            onTap: () => Navigator.of(context).pop(option),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
