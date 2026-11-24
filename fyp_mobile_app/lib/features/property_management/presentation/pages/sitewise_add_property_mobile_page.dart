import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/core/config/mobile_config.dart';
import 'package:fyp/core/theme/sitewise_m3.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/shared/presentation/layouts/mobile_app_shell.dart';
import 'package:fyp/core/routing/mobile_navigation.dart';
import 'package:fyp/shared/presentation/layouts/provider_tab_scope.dart';

/// SiteWise Add Property — the ONE create/edit form for the whole Provider
/// workspace, reused unchanged by Property Owners and Agents.
///
/// `/provider/add-property` is its only live route and both provider roles are
/// sent there; no role gets its own copy. What differs between them is decided
/// server-side from the verified token — an owner's new row records ownership,
/// an agent's records the existing management assignment — never by a second
/// form.
///
/// Drafts persist in PostgreSQL (`fyp.rental_properties` with
/// ``verification_status='draft'``) through the authenticated FastAPI
/// endpoints; submitting hands the record to the existing property
/// verification workflow (documents -> submit -> admin review). There is no
/// local-only state here: every save is a server round trip, and the
/// confirmation step shows the real database-assigned property ID.
class SitewiseAddPropertyMobilePage extends StatefulWidget {
  /// Resume an existing draft (`fyp.rental_properties.id`) from
  /// My listings. Null starts a blank form.
  final String? initialDraftId;

  const SitewiseAddPropertyMobilePage({super.key, this.initialDraftId});

  @override
  State<SitewiseAddPropertyMobilePage> createState() =>
      _SitewiseAddPropertyMobilePageState();
}

class _SitewiseAddPropertyMobilePageState
    extends State<SitewiseAddPropertyMobilePage> {
  // The Add Property form is the Provider workspace's Add destination. Its
  // palette now points at the shared SiteWise design system instead of
  // carrying a private copy that drifted from the entrepreneur screens.
  static const Color _brand = SitewiseColors.action;
  static const Color _brandStrong = SitewiseM3.primary;
  static const Color _background = SitewiseM3.paper;
  static const Color _ink = SitewiseM3.ink;
  static const Color _muted = SitewiseM3.muted;
  static const Color _border = SitewiseM3.line;
  static const Color _errorInk = Color(0xFFB42318);
  static const Color _errorBorder = Color(0xFFE7A6A0);

  static const List<String> _stepNames = <String>[
    'Property details',
    'Location & extras',
    'Agent verification',
    'Review',
    'Confirmation',
  ];

  static const List<String> _stepDescriptions = <String>[
    'Enter the basic details of your commercial unit.',
    'Add the address and any optional property details.',
    'An authorized Agent will independently inspect and capture the 360° tour.',
    'Check the details before saving your draft.',
    'Save the property as a draft. Assign an Agent later in Requests.',
  ];

  // The one Agent/Owner Add Property form offers only two property types.
  static const List<String> _supportedPropertyTypes = <String>[
    'Shoplot',
    'Retail Space',
  ];

  static String _newDraftRequestId() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  // Cache the theme. Keyboard opening/closing should not allocate and
  // propagate an entirely new ThemeData through the input-heavy wizard.
  late final ThemeData _formTheme = ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: _background,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _brand,
      primary: _brand,
      surface: SitewiseM3.surface,
    ),
    fontFamily: kFontFamily,
  );

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _rentController = TextEditingController();
  final TextEditingController _areaController = TextEditingController();
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _stateController = TextEditingController();
  final TextEditingController _districtController = TextEditingController();
  final TextEditingController _postcodeController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  // SITEWISE_OWNER_OPTIONAL_FIELDS_PRESERVE_V1
  // Stored on the existing listing: not new tables or verification flags.
  final TextEditingController _availabilityController = TextEditingController();
  final TextEditingController _floorLevelController = TextEditingController();
  final TextEditingController _frontageController = TextEditingController();
  final TextEditingController _leaseMonthsController = TextEditingController();
  final TextEditingController _depositController = TextEditingController();

  int _step = 1;
  String _propertyType = 'Shoplot';
  String? _floorDescription;
  String? _unitPosition;
  String? _furnishing;
  String? _parkingChoice;
  String? _leaseChoice;
  String? _tenure;
  String? _titleType;
  String? _landlordPermission;
  String? _legacyAvailability;
  DateTime? _availableFrom;
  final String _draftRequestId = _newDraftRequestId();
  String? _validationMessage;

  /// Field-specific errors, rendered under the relevant control. The shared
  /// [PropertyFormRules] produce the messages so web and mobile agree.
  final Map<String, String> _fieldErrors = <String, String>{};

  // Server state: the persisted PostgreSQL draft and its lifecycle.
  String? _draftId;
  String _serverStatus = 'draft';
  String? _rejectionReason;
  bool _saving = false;
  String? _serverMessage;
  String? _serverError;

  String get _propertyName => _nameController.text.trim();
  String get _monthlyRent => _rentController.text.trim();
  String get _builtUpArea => _areaController.text.trim();
  String get _address => _addressController.text.trim();
  String get _stateName => _stateController.text.trim();
  String get _district => _districtController.text.trim();
  String get _postcode => _postcodeController.text.trim();
  String get _availability => _availabilityController.text.trim();
  String get _floorLevel => _floorLevelController.text.trim();
  String get _frontage => _frontageController.text.trim();
  String get _leaseMonths => _leaseMonthsController.text.trim();
  String get _deposit => _depositController.text.trim();
  String? get _numericFloor => switch (_floorDescription) {
    'Basement' => '-1',
    'Ground floor' => '0',
    'First floor' => '1',
    'Second floor' => '2',
    'Third floor or above' => _floorLevel.isEmpty ? null : _floorLevel,
    _ => null,
  };
  int? get _leaseMonthsForRequest => switch (_leaseChoice) {
    '6 months' => 6,
    '1 year' => 12,
    '2 years' => 24,
    '3 years' => 36,
    'Other duration' => int.tryParse(_leaseMonths),
    _ => null,
  };
  bool? get _parkingValue => switch (_parkingChoice) {
    'Available' => true,
    'Not available' => false,
    _ => null,
  };
  bool? get _leaseNegotiable =>
      _leaseChoice == null ? null : _leaseChoice == 'Negotiable';

  /// The record can only be edited while the backend policy allows it
  /// (draft, rejected or corrections-requested). The backend enforces the
  /// same rule; this only disables the UI honestly.
  bool get _editable =>
      _draftId == null ||
      _serverStatus == 'draft' ||
      _serverStatus == 'rejected';

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
    _availabilityController.dispose();
    _floorLevelController.dispose();
    _frontageController.dispose();
    _leaseMonthsController.dispose();
    _depositController.dispose();
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
        _serverError = _readableError(
          error,
          fallback: 'Could not load the saved draft.',
        );
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

    // Never round persisted values before returning them to an editable form:
    // editing an unrelated field must not change rent or area implicitly.
    String originalNumber(double? value) {
      if (value == null) return '';
      return value == value.truncateToDouble()
          ? value.toStringAsFixed(0)
          : value.toString();
    }

    text(_nameController, listing.name);
    text(_rentController, originalNumber(listing.rentalPrice));
    text(_areaController, originalNumber(listing.sizeSqft));
    text(_addressController, listing.address);
    text(_stateController, listing.state);
    text(_districtController, listing.city);
    text(_postcodeController, listing.postcode);
    text(_descriptionController, listing.description);
    final availabilityOptions = propertyAvailabilityOptions;
    _legacyAvailability =
        listing.availability != null &&
            !availabilityOptions.contains(listing.availability)
        ? listing.availability
        : null;
    text(
      _availabilityController,
      availabilityOptions.contains(listing.availability)
          ? listing.availability
          : null,
    );
    text(_floorLevelController, originalNumber(listing.floorLevel));
    text(_frontageController, originalNumber(listing.frontageFt));
    text(_leaseMonthsController, listing.leaseDurationMonths?.toString());
    text(_depositController, originalNumber(listing.rentalDepositMyr));
    _floorDescription =
        listing.floorDescription ??
        switch (listing.floorLevel) {
          -1 => 'Basement',
          0 => 'Ground floor',
          1 => 'First floor',
          2 => 'Second floor',
          final value? when value >= 3 => 'Third floor or above',
          _ => null,
        };
    _unitPosition = listing.unitPosition;
    _furnishing = listing.furnishing;
    _parkingChoice = listing.hasParking == null
        ? null
        : listing.hasParking!
        ? 'Available'
        : 'Not available';
    _leaseChoice = listing.leaseDurationNegotiable == true
        ? 'Negotiable'
        : switch (listing.leaseDurationMonths) {
            6 => '6 months',
            12 => '1 year',
            24 => '2 years',
            36 => '3 years',
            _? => 'Other duration',
            _ => null,
          };
    _tenure = listing.tenure;
    _titleType = listing.titleType;
    _landlordPermission = listing.landlordFnbPermission;
    _availableFrom = DateTime.tryParse(listing.availableFrom ?? '');
    final normalizedType = normalizeCommercialPropertyType(
      listing.propertyType,
    );
    // Existing drafts are not rewritten automatically. If an older
    // type is no longer offered, require the user to choose one.
    _propertyType =
        normalizedType != null &&
            _supportedPropertyTypes.contains(normalizedType)
        ? normalizedType
        : '';
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

  Map<String, dynamic> _draftFields() =>
      OwnerListing(
          id: _draftId ?? '',
          name: '',
          verificationStatus: _serverStatus,
        ).toDraftJson(
          name: _propertyName.isEmpty ? null : _propertyName,
          propertyType: _propertyType,
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          address: _address.isEmpty ? null : _address,
          city: _district.isEmpty ? null : _district,
          state: _stateName.isEmpty ? null : _stateName,
          postcode: _postcode.isEmpty ? null : _postcode,
          rentalPrice: double.tryParse(_monthlyRent),
          sizeSqft: double.tryParse(_builtUpArea),
          availability: _availability.isEmpty ? null : _availability,
          floorLevel: _numericFloor,
          floorDescription: _floorDescription,
          frontageFt: _frontage.isEmpty ? null : double.tryParse(_frontage),
          furnishing: _furnishing,
          tenure: _tenure,
          unitPosition: _unitPosition,
          hasParking: _parkingValue,
          leaseDurationMonths: _leaseMonthsForRequest,
          leaseDurationNegotiable: _leaseNegotiable,
          availableFrom: _availableFrom == null
              ? null
              : '${_availableFrom!.year.toString().padLeft(4, '0')}-'
                    '${_availableFrom!.month.toString().padLeft(2, '0')}-'
                    '${_availableFrom!.day.toString().padLeft(2, '0')}',
          rentalDepositMyr: _deposit.isEmpty ? null : double.tryParse(_deposit),
          titleType: _titleType,
          landlordFnbPermission: _landlordPermission,
          draftRequestId: _draftRequestId,
        )
        ..removeWhere(
          (key, _) =>
              key == 'availability' &&
              _availability.isEmpty &&
              _legacyAvailability != null,
        );

  /// Save Draft: create the row once, then update the SAME row. The backend
  /// stamps the owner from the verified token and assigns the persistent id.
  // SITEWISE_ADD_PROPERTY_EXPLICIT_DRAFT_V1
  // Persist the row first; only an acknowledged server save is a success.
  Future<bool> _saveDraft() async {
    if (_saving) return false;
    if (!_live) {
      setState(() {
        _serverError =
            'Draft saving requires the live Sitewise service '
            '(a demo build keeps no property records).';
      });
      return false;
    }
    // Partial drafts are allowed, but invalid optional values are not.
    _fieldErrors.remove('availability');
    _fieldErrors.remove('floor_level');
    _fieldErrors.remove('frontage_ft');
    _collectOptionalDetailsErrors();
    if (_fieldErrors.containsKey('availability') ||
        _fieldErrors.containsKey('floor_level') ||
        _fieldErrors.containsKey('frontage_ft') ||
        _fieldErrors.containsKey('rental_deposit_myr') ||
        _fieldErrors.containsKey('lease_duration')) {
      setState(() {
        _step = 2;
        _validationMessage = 'Correct the optional details before saving.';
      });
      return false;
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
      if (!mounted) return false;
      setState(() {
        _draftId = saved.id;
        _serverStatus = saved.verificationStatus;
        _serverMessage =
            'Draft saved to Sitewise (ID ${saved.id}). '
            'You can leave this page and resume it later from My listings.';
      });
      return true;
    } on Object catch (error) {
      if (!mounted) return false;
      setState(() {
        _serverError = _readableError(
          error,
          fallback: 'Could not save the draft.',
        );
      });
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
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
    _putField(
      'type',
      _supportedPropertyTypes.contains(_propertyType)
          ? PropertyFormRules.propertyTypeError(_propertyType)
          : 'Choose Shoplot or Retail Space.',
    );
    _putField('area', PropertyFormRules.areaError(_builtUpArea));
    _putField(
      'floor_description',
      PropertyFormRules.optionError(
        _floorDescription,
        propertyFloorOptions,
        'the floor level',
      ),
    );
    _putField(
      'floor_level',
      PropertyFormRules.floorNumberError(_floorDescription, _floorLevel),
    );
    _putField(
      'furnishing',
      PropertyFormRules.optionError(
        _furnishing,
        propertyFurnishingOptions,
        'the furnishing condition',
      ),
    );
  }

  void _collectLocationErrors() {
    _putField('rent', PropertyFormRules.rentError(_monthlyRent));
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
    _putField(
      'availability',
      PropertyFormRules.optionError(
        _availability,
        propertyAvailabilityOptions,
        'availability',
      ),
    );
    _putField(
      'available_from',
      PropertyFormRules.availableDateError(
        _availability,
        _availableFrom == null ? null : 'set',
      ),
    );
    _putField(
      'lease_duration',
      PropertyFormRules.leaseDurationError(_leaseChoice, _leaseMonths),
    );
    _putField(
      'landlord_fnb_permission',
      PropertyFormRules.optionError(
        _landlordPermission,
        landlordFnbPermissionOptions,
        'landlord permission for F&B use',
      ),
    );
    _collectOptionalDetailsErrors();
  }

  void _collectOptionalDetailsErrors() {
    final frontage = _frontage.isEmpty ? null : double.tryParse(_frontage);
    if (_frontage.isNotEmpty &&
        (frontage == null ||
            !frontage.isFinite ||
            frontage < 0 ||
            frontage > 10000)) {
      _putField('frontage_ft', 'Enter a valid frontage in feet.');
    }
    final deposit = _deposit.isEmpty ? null : double.tryParse(_deposit);
    if (_deposit.isNotEmpty &&
        (deposit == null ||
            !deposit.isFinite ||
            deposit < 0 ||
            deposit > 10000000)) {
      _putField('rental_deposit_myr', 'Enter a non-negative rental deposit.');
    }
    if (_leaseChoice == 'Other duration' &&
        PropertyFormRules.leaseDurationError(_leaseChoice, _leaseMonths) !=
            null) {
      _putField('lease_duration', 'Enter a duration between 1 and 360 months.');
    }
    _putField(
      'unit_position',
      PropertyFormRules.optionError(
        _unitPosition,
        propertyUnitPositions,
        'the unit position',
        required: false,
      ),
    );
    _putField(
      'tenure',
      PropertyFormRules.optionError(
        _tenure,
        propertyTenureOptions,
        'the land tenure',
        required: false,
      ),
    );
    _putField(
      'title_type',
      PropertyFormRules.optionError(
        _titleType,
        propertyTitleTypeOptions,
        'the property title type',
        required: false,
      ),
    );
    _putField(
      'parking',
      PropertyFormRules.optionError(
        _parkingChoice,
        propertyParkingOptions,
        'parking availability',
        required: false,
      ),
    );
  }

  void _putField(String key, String? message) {
    if (message != null) _fieldErrors[key] = message;
  }

  Future<void> _goNext() async {
    if (_step >= 5 || _saving) return;
    FocusManager.instance.primaryFocus?.unfocus();
    // On review, the existing form rules must still pass. The record is
    // committed before opening the confirmation page.
    if (!_validateCurrentStep()) {
      if (mounted) setState(() {});
      return;
    }
    if (_step == 4) {
      final persisted = await _saveDraft();
      if (!mounted || !persisted) return;
    }
    if (!mounted) return;
    setState(() {
      _step += 1;
      _validationMessage = null;
    });
  }

  void _goBack() {
    if (_step <= 1) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _step -= 1;
      _validationMessage = null;
    });
  }

  void _editStep(int step) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _step = step;
      _validationMessage = null;
    });
    // Step 3 is the only step whose actions depend on persisted state: whether
    // an interrupted capture exists decides if "Resume" may be shown at all.
  }

  void _onTextChanged(String _) {
    // TextField updates itself through its controller. Rebuilding the whole
    // page on every character causes unnecessary keyboard/input jank.
    if (_validationMessage == null) return;
    setState(() => _validationMessage = null);
  }

  /// Leave the form for the signed-in role's property listing.
  ///
  /// Inside the Provider shell the listing tab already exists, so the dock
  /// command simply selects it and the form page is kept alive. A draft resumed
  /// as a drill-in cannot see that scope; it pops with [addPropertyDoneResult]
  /// and the shell re-selects `/provider/listings`. A cold deep link has no
  /// shell underneath it, and only that case rebuilds the stack.
  void _goToListings() {
    const listings = '/provider/listings';
    final scope = ProviderTabScope.maybeOf(context);
    if (scope != null && scope.handlesRoute(listings)) {
      scope.go(listings);
      return;
    }
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop(addPropertyDoneResult);
    } else {
      navigator.pushNamedAndRemoveUntil(listings, (route) => false);
    }
  }

  /// Dock taps while the form is open are tab commands, not new routes.
  ///
  /// When the form is the persistent Provider page the scope is present and
  /// `IndexedStack` switches tabs with no rebuild or second AuthGuard pass. A
  /// resumed draft has no scope: popping with a tab result returns to the shell
  /// that opened it, and a cold deep link falls back to the original route
  /// replacement so the workspace is never stacked twice.
  void _onDockNavigate(String route) {
    final scope = ProviderTabScope.maybeOf(context);
    if (scope != null && scope.handlesRoute(route)) {
      scope.go(route);
      return;
    }
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop(providerTabResult(route));
      return;
    }
    navigator.pushReplacementNamed(route);
  }

  /// The dock route to highlight while the form is open.
  ///
  /// The owner dock carries an Add slot; the agent dock does not, so the agent
  /// keeps their listing tab selected rather than falling back to Home.
  String _dockRouteFor(List<MobileDestination> destinations) =>
      destinations.any((d) => d.route == '/provider/add-property')
      ? '/provider/add-property'
      : '/provider/listings';

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _formTheme,
      child: Consumer(
        builder: (context, ref, _) {
          // ONE form serves the whole Provider workspace: an owner and an agent
          // both land here, and the only thing that differs between them is the
          // role-scoped dock and what the backend records against the new row
          // (ownership for an owner, an agent assignment for an agent).
          final role = ref.watch(appNotifierProvider.select((s) => s.role));
          final destinations = providerDestinationsFor(role);
          return MobileAppShell(
            title: 'Add property',
            currentRoute: _dockRouteFor(destinations),
            // This form is the Provider dock's Add destination: keep the exact
            // Material 3 chrome and the role's provider tabs while it is open.
            m3: true,
            destinations: destinations,
            hideBottomNavOnKeyboard: true,
            onNavigate: _onDockNavigate,
            // Entered from the Owner / Agent workspace as a top-level Add
            // destination, so the header keeps no back arrow — the dock is the
            // way back to the other tabs.
            showBack: false,
            body: SafeArea(
              child: SingleChildScrollView(
                // Let the user drag to dismiss the keyboard without forcing
                // the entire provider wizard through extra input rebuilds.
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
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
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPageHeading() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'PROVIDER WORKSPACE',
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
              ? 'Fill in the property details. On Review, tap Save draft '
                    'to create the listing in My listings.'
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
                        _step == 4 ? 'Save draft' : 'Continue →',
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
        return _buildAgentHandoff();
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
          label: 'Built-up area (sq ft)',
          controller: _areaController,
          requiredField: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          error: _fieldErrors['area'],
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 17),
        _buildSelectField(
          label: 'Floor level',
          value: _floorDescription ?? '',
          hint: 'Select the floor level',
          options: propertyFloorOptions,
          requiredField: true,
          searchable: false,
          error: _fieldErrors['floor_description'],
          onSelected: (value) => setState(() {
            _floorDescription = value;
            if (value != 'Third floor or above') _floorLevelController.clear();
            _fieldErrors.remove('floor_description');
            _fieldErrors.remove('floor_level');
          }),
        ),
        if (_floorDescription == 'Third floor or above') ...[
          const SizedBox(height: 14),
          _buildTextField(
            label: 'Floor number',
            controller: _floorLevelController,
            requiredField: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            hint: 'For example, 4',
            error: _fieldErrors['floor_level'],
          ),
        ],
        const SizedBox(height: 17),
        _buildSelectField(
          label: 'Unit position',
          value: _unitPosition ?? '',
          hint: 'Optional',
          options: propertyUnitPositions,
          searchable: false,
          error: _fieldErrors['unit_position'],
          onSelected: (value) => setState(() => _unitPosition = value),
        ),
        const SizedBox(height: 17),
        _buildTextField(
          label: 'Shop frontage (ft)',
          controller: _frontageController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          hint: 'Optional',
          error: _fieldErrors['frontage_ft'],
        ),
        const SizedBox(height: 17),
        _buildSelectField(
          label: 'Furnishing condition',
          value: _furnishing ?? '',
          hint: 'Select a condition',
          options: propertyFurnishingOptions,
          requiredField: true,
          searchable: false,
          error: _fieldErrors['furnishing'],
          onSelected: (value) => setState(() {
            _furnishing = value;
            _fieldErrors.remove('furnishing');
          }),
        ),
        const SizedBox(height: 17),
        _buildSelectField(
          label: 'Parking availability',
          value: _parkingChoice ?? '',
          hint: 'Optional — choose Not sure if unknown',
          options: propertyParkingOptions,
          searchable: false,
          error: _fieldErrors['parking'],
          onSelected: (value) => setState(() => _parkingChoice = value),
        ),
        const SizedBox(height: 17),
        _buildTextField(
          label: 'Description (optional)',
          controller: _descriptionController,
          hint:
              'Describe the property condition, layout, facilities and other relevant information.',
          maxLines: 4,
        ),
        const SizedBox(height: 19),
        const Divider(height: 1, color: Color(0xFFEEF1F5)),
        const SizedBox(height: 17),
        _buildChoiceGrid(),
        const SizedBox(height: 16),
        _buildInfoNotice(
          'Saving creates a real draft record. Only an authorized Agent may '
          'capture its 360° tour and submit it for Admin verification.',
        ),
      ],
    );
  }

  Widget _buildChoiceGrid() {
    final choices = _supportedPropertyTypes;
    final error = _fieldErrors['type'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _fieldLabel('Commercial property type', requiredField: true),
        const SizedBox(height: 9),
        // Avoid a nested shrink-wrapped GridView. Keyboard height changes
        // re-layout the form; Wrap is lighter for this small, fixed set.
        LayoutBuilder(
          builder: (context, constraints) {
            const gap = 9.0;
            final tileWidth = (constraints.maxWidth - gap) / 2;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: <Widget>[
                for (final choice in choices)
                  SizedBox(
                    width: tileWidth,
                    height: 52,
                    child: OutlinedButton(
                      onPressed: () {
                        FocusManager.instance.primaryFocus?.unfocus();
                        setState(() {
                          _propertyType = choice;
                          _fieldErrors.remove('type');
                          _validationMessage = null;
                        });
                      },
                      style: OutlinedButton.styleFrom(
                        backgroundColor: choice == _propertyType
                            ? const Color(0xFFEEF5FF)
                            : Colors.white,
                        foregroundColor: choice == _propertyType
                            ? _brandStrong
                            : _muted,
                        side: BorderSide(
                          color: choice == _propertyType
                              ? const Color(0xFF81A8FB)
                              : const Color(0xFFD6DEEA),
                          width: choice == _propertyType ? 1.5 : 1,
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
                    ),
                  ),
              ],
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
        _sectionTitle('Rental information'),
        _buildTextField(
          label: 'Monthly rental (RM)',
          controller: _rentController,
          requiredField: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          error: _fieldErrors['rent'],
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 15),
        _buildSelectField(
          label: 'Minimum rental period',
          value: _leaseChoice ?? '',
          hint: 'Select a minimum period',
          options: propertyLeaseOptions,
          requiredField: true,
          searchable: false,
          error: _fieldErrors['lease_duration'],
          onSelected: (value) => setState(() {
            _leaseChoice = value;
            if (value != 'Other duration') _leaseMonthsController.clear();
            _fieldErrors.remove('lease_duration');
          }),
        ),
        if (_leaseChoice == 'Other duration') ...[
          const SizedBox(height: 14),
          _buildTextField(
            label: 'Rental period (months)',
            controller: _leaseMonthsController,
            requiredField: true,
            keyboardType: TextInputType.number,
            hint: '1 to 360 months',
            error: _fieldErrors['lease_duration'],
          ),
        ],
        const SizedBox(height: 15),
        _buildSelectField(
          label: 'Availability',
          value: _availability,
          hint: 'Select availability',
          options: propertyAvailabilityOptions,
          requiredField: true,
          searchable: false,
          helper: _legacyAvailability == null
              ? null
              : 'Existing value: $_legacyAvailability. Select an option to update it.',
          error: _fieldErrors['availability'],
          onSelected: (value) => setState(() {
            _availabilityController.text = value;
            _legacyAvailability = null;
            if (value != 'Available from a specific date') {
              _availableFrom = null;
            }
            _fieldErrors.remove('availability');
          }),
        ),
        if (_availability == 'Available from a specific date') ...[
          const SizedBox(height: 14),
          _dateField(),
        ],
        const SizedBox(height: 15),
        _buildTextField(
          label: 'Rental deposit (RM)',
          controller: _depositController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          hint: 'Optional',
          error: _fieldErrors['rental_deposit_myr'],
        ),
        const SizedBox(height: 15),
        _buildSelectField(
          label: 'Landlord permission for F&B use',
          value: _landlordPermission ?? '',
          hint: 'Select the owner-declared status',
          options: landlordFnbPermissionOptions,
          requiredField: true,
          searchable: false,
          helper:
              'This is an owner declaration, not licensing approval or a suitability result.',
          error: _fieldErrors['landlord_fnb_permission'],
          onSelected: (value) => setState(() {
            _landlordPermission = value;
            _fieldErrors.remove('landlord_fnb_permission');
          }),
        ),
        const SizedBox(height: 14),
        _rentalRateSummary(),
        const SizedBox(height: 22),
        _sectionTitle('Ownership information'),
        _buildSelectField(
          label: 'Land tenure',
          value: _tenure ?? '',
          hint: 'Optional',
          options: propertyTenureOptions,
          searchable: false,
          error: _fieldErrors['tenure'],
          onSelected: (value) => setState(() => _tenure = value),
        ),
        const SizedBox(height: 15),
        _buildSelectField(
          label: 'Property title type',
          value: _titleType ?? '',
          hint: 'Optional',
          options: propertyTitleTypeOptions,
          searchable: false,
          error: _fieldErrors['title_type'],
          onSelected: (value) => setState(() => _titleType = value),
        ),
        const SizedBox(height: 10),
        _buildInfoNotice(
          'Freehold or title-type selections are owner-provided information, not legal ownership verification.',
        ),
        const SizedBox(height: 22),
        _sectionTitle('Property address'),
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
        _buildInfoNotice(
          'Your address is checked through the existing server workflow. Saving rental terms never overwrites verified coordinates.',
        ),
      ],
    );
  }

  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      title,
      style: const TextStyle(
        color: _ink,
        fontSize: 16,
        fontWeight: FontWeight.w800,
      ),
    ),
  );

  Widget _rentalRateSummary() {
    final rent = double.tryParse(_monthlyRent);
    final area = double.tryParse(_builtUpArea);
    final psf = rent != null && area != null && area > 0 ? rent / area : null;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F8FC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Text(
        psf == null
            ? 'Rental per square foot will be calculated from monthly rent and built-up area.'
            : 'Rental per square foot: RM ${psf.toStringAsFixed(2)} / sq ft',
        style: const TextStyle(
          color: _ink,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _dateField() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _fieldLabel('Available-from date', requiredField: true),
      const SizedBox(height: 7),
      SizedBox(
        height: 50,
        child: OutlinedButton.icon(
          onPressed: _editable ? _pickAvailableDate : null,
          icon: const Icon(Icons.calendar_today_outlined, size: 18),
          label: Text(
            _availableFrom == null
                ? 'Choose a date'
                : MaterialLocalizations.of(
                    context,
                  ).formatMediumDate(_availableFrom!),
          ),
          style: OutlinedButton.styleFrom(
            alignment: Alignment.centerLeft,
            foregroundColor: _ink,
            side: BorderSide(
              color: _fieldErrors['available_from'] == null
                  ? _border
                  : _errorBorder,
            ),
          ),
        ),
      ),
      if (_fieldErrors['available_from'] != null) ...[
        const SizedBox(height: 6),
        _buildFieldError(_fieldErrors['available_from']!),
      ],
    ],
  );

  Future<void> _pickAvailableDate() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: _availableFrom ?? today,
      firstDate: today,
      lastDate: DateTime(today.year + 5),
    );
    if (!mounted || picked == null) return;
    setState(() {
      _availableFrom = picked;
      _fieldErrors.remove('available_from');
    });
  }

  void _onAddressChanged(String value) {
    final removedError = _fieldErrors.remove('address') != null;
    if (!removedError && _validationMessage == null) return;
    setState(() => _validationMessage = null);
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

  Widget _buildAgentHandoff() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Icon(
        Icons.verified_user_outlined,
        color: SitewiseColors.action,
        size: 36,
      ),
      const SizedBox(height: 12),
      const Text(
        'How verification works',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 14),
      _handoffRole(
        'Property owner',
        'Provides property information, submits ownership or authorization proof, and requests an authorized Agent inspection.',
      ),
      const SizedBox(height: 12),
      _handoffRole(
        'Assigned Agent',
        'Reviews your details, checks observable physical characteristics, records discrepancies, completes the existing 38-target 360° capture, previews its generated panorama, and submits the inspection to Admin.',
      ),
      const SizedBox(height: 12),
      _handoffRole(
        'Administrator',
        'Reviews the listing, ownership evidence, Agent findings and panorama, then makes the final verification decision.',
      ),
      const SizedBox(height: 12),
      _buildInfoNotice(
        'Owners do not perform 360° capture. Uploading ownership evidence does not itself complete verification.',
      ),
    ],
  );

  Widget _handoffRole(String heading, String details) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: const Color(0xFFF8FAFD),
      border: Border.all(color: _border),
      borderRadius: BorderRadius.circular(11),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          heading,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: _ink,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          details,
          style: const TextStyle(fontSize: 14, height: 1.45, color: _muted),
        ),
      ],
    ),
  );

  Widget _buildReview() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildReviewSection(
          title: 'Property characteristics',
          step: 1,
          rows: <_ReviewRow>[
            _ReviewRow('Property title', _display(_propertyName)),
            _ReviewRow('Commercial property type', _display(_propertyType)),
            _ReviewRow(
              'Built-up area',
              _builtUpArea.isEmpty ? 'Not provided' : '$_builtUpArea sq ft',
            ),
            _ReviewRow('Floor level', _display(_floorDescription ?? '')),
            _ReviewRow(
              'Floor number',
              _floorLevel.isEmpty ? 'Not applicable' : _floorLevel,
            ),
            _ReviewRow('Unit position', _display(_unitPosition ?? '')),
            _ReviewRow(
              'Shop frontage',
              _frontage.isEmpty ? 'Not provided' : '$_frontage ft',
            ),
            _ReviewRow('Furnishing condition', _display(_furnishing ?? '')),
            _ReviewRow('Parking availability', _display(_parkingChoice ?? '')),
            _ReviewRow(
              'Description',
              _display(_descriptionController.text.trim()),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _buildReviewSection(
          title: 'Rental terms',
          step: 2,
          rows: <_ReviewRow>[
            _ReviewRow(
              'Monthly rental',
              _monthlyRent.isEmpty ? 'Not provided' : 'RM $_monthlyRent',
            ),
            _ReviewRow(
              'Built-up area',
              _builtUpArea.isEmpty ? 'Not provided' : '$_builtUpArea sq ft',
            ),
            _ReviewRow('Rental per square foot', _rentalPerSqftLabel),
            _ReviewRow(
              'Minimum rental period',
              _leaseChoice == 'Other duration' && _leaseMonths.isNotEmpty
                  ? 'Other duration — $_leaseMonths months'
                  : _display(_leaseChoice ?? ''),
            ),
            _ReviewRow(
              'Availability',
              _display(
                _availability.isEmpty
                    ? (_legacyAvailability ?? '')
                    : _availability,
              ),
            ),
            _ReviewRow(
              'Available from',
              _availableFrom == null
                  ? 'Not applicable'
                  : MaterialLocalizations.of(
                      context,
                    ).formatMediumDate(_availableFrom!),
            ),
            _ReviewRow(
              'Rental deposit',
              _deposit.isEmpty ? 'Not provided' : 'RM $_deposit',
            ),
            _ReviewRow(
              'Landlord permission for F&B use',
              _display(_landlordPermission ?? ''),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _buildReviewSection(
          title: 'Ownership information',
          step: 2,
          rows: <_ReviewRow>[
            _ReviewRow('Land tenure', _display(_tenure ?? '')),
            _ReviewRow('Property title type', _display(_titleType ?? '')),
          ],
        ),
        const SizedBox(height: 18),
        _buildReviewSection(
          title: 'Address',
          step: 2,
          rows: <_ReviewRow>[
            _ReviewRow('Street address', _display(_address)),
            _ReviewRow('State / federal territory', _display(_stateName)),
            _ReviewRow('City / township', _display(_district)),
            _ReviewRow('Postcode', _display(_postcode)),
          ],
        ),
        const SizedBox(height: 18),
        _buildReviewSection(
          title: 'Agent verification requirements',
          step: 3,
          rows: const <_ReviewRow>[
            _ReviewRow(
              'Owner action',
              'Submit ownership or authorization proof and request an Agent',
            ),
            _ReviewRow(
              'Agent action',
              'Inspect physical facts, capture and preview a 360° panorama, then submit to Admin',
            ),
            _ReviewRow('Final decision', 'Administrator review'),
          ],
        ),
        const SizedBox(height: 16),
        _buildInfoNotice(
          'Review all required details before saving. The property remains an unpublished draft until the existing verification workflow is completed.',
        ),
      ],
    );
  }

  String get _rentalPerSqftLabel {
    final rent = double.tryParse(_monthlyRent);
    final area = double.tryParse(_builtUpArea);
    if (rent == null || area == null || area <= 0) return 'Not derivable';
    return 'RM ${(rent / area).toStringAsFixed(2)} / sq ft';
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

  Future<void> _verifySavedAddress() async {
    final id = _draftId;
    if (id == null || _saving) return;
    setState(() {
      _saving = true;
      _serverError = null;
    });
    try {
      final status = await ServiceLocator.ownerListings.validateSavedAddress(
        id,
      );
      if (mounted) {
        setState(
          () => _serverMessage =
              'Address verification: ${status.replaceAll('_', ' ')}.',
        );
      }
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _serverError = _readableError(
            error,
            fallback: 'Could not verify the saved address.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildConfirmation() {
    final saved = _draftId != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 28, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(
            saved ? Icons.check_circle_outline_rounded : Icons.error_outline,
            color: saved ? const Color(0xFF087443) : _errorInk,
            size: 52,
          ),
          const SizedBox(height: 14),
          Text(
            saved ? 'Property saved as draft' : 'Property not saved yet',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _ink,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            saved
                ? 'Your listing is now in My listings. Ownership proof and '
                      'Agent requests are separate next steps.'
                : 'Please save the property before leaving this page.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted, fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 22),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: _border),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('Property', style: TextStyle(color: _muted)),
                const SizedBox(height: 4),
                Text(
                  _display(_propertyName),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 12),
                const Text(
                  'Database property ID',
                  style: TextStyle(color: _muted),
                ),
                const SizedBox(height: 4),
                Text(
                  _draftId ?? 'Not assigned',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Status: ${_serverStatus.replaceAll('_', ' ')} · Not published',
                  style: const TextStyle(color: _muted, fontSize: 14),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (saved)
            OutlinedButton.icon(
              onPressed: _saving ? null : _verifySavedAddress,
              icon: const Icon(Icons.location_on_outlined),
              label: const Text('Verify saved address'),
            ),
          FilledButton.icon(
            onPressed: saved && !_saving ? _viewSavedProperty : null,
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('View property details'),
            style: FilledButton.styleFrom(
              backgroundColor: _brand,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(52),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: saved && !_saving ? _goToListings : null,
            icon: const Icon(Icons.list_alt_outlined),
            label: const Text(
              'Go to My Listings to add proof or request an Agent',
            ),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
          ),
        ],
      ),
    );
  }

  void _viewSavedProperty() {
    final propertyId = int.tryParse(_draftId ?? '');
    if (propertyId == null) return;
    Navigator.of(
      context,
    ).pushNamed('/provider/property-detail', arguments: propertyId);
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
          // The scaffold already keeps the scroll viewport above the keyboard.
          scrollPadding: const EdgeInsets.all(20),
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
  static const Color _ink = SitewiseM3.ink;
  static const Color _muted = SitewiseM3.muted;
  static const Color _brand = SitewiseColors.action;

  static const int _maxVisibleOptions = 100;
  static const Duration _searchDebounceDuration = Duration(milliseconds: 120);

  final TextEditingController _filter = TextEditingController();
  Timer? _searchTimer;
  late final List<String> _lowercaseOptions;
  List<String> _visible = const <String>[];
  bool _showNarrowHint = false;

  List<String> _initialOptions() {
    // Preserve the selected entry even when it lies after the first 100.
    final result = <String>[];
    if (widget.selected.isNotEmpty &&
        widget.options.contains(widget.selected)) {
      result.add(widget.selected);
    }
    for (final option in widget.options) {
      if (option == widget.selected) continue;
      if (result.length == _maxVisibleOptions) break;
      result.add(option);
    }
    return result;
  }

  @override
  void initState() {
    super.initState();
    // Lowercasing all locations on every keystroke can freeze low-end devices.
    // Compute once, and render no more than 100 list tiles per search.
    _lowercaseOptions = widget.options
        .map((option) => option.toLowerCase())
        .toList(growable: false);
    _visible = _initialOptions();
    _showNarrowHint = widget.options.length > _maxVisibleOptions;
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _filter.dispose();
    super.dispose();
  }

  void _applyFilter(String query) {
    _searchTimer?.cancel();
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) {
      setState(() {
        _visible = _initialOptions();
        _showNarrowHint = widget.options.length > _maxVisibleOptions;
      });
      return;
    }

    _searchTimer = Timer(_searchDebounceDuration, () {
      if (!mounted) return;
      final matches = <String>[];
      var hasMore = false;
      for (var i = 0; i < _lowercaseOptions.length; i++) {
        if (!_lowercaseOptions[i].contains(needle)) continue;
        if (matches.length == _maxVisibleOptions) {
          hasMore = true;
          break;
        }
        matches.add(widget.options[i]);
      }
      if (!mounted) return;
      setState(() {
        _visible = matches;
        _showNarrowHint = hasMore;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    // Reserve keyboard space *before* determining sheet height. Previously,
    // a 68%-screen sheet PLUS the keyboard inset caused repeated constraint
    // and viewport churn (and occasional overflow on smaller devices).
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final topPadding = MediaQuery.paddingOf(context).top;
    final availableHeight = (screenHeight - keyboardInset - topPadding).clamp(
      0.0,
      screenHeight,
    );
    final height = availableHeight * (keyboardInset > 0 ? 0.92 : 0.68);
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
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
              if (_showNarrowHint)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 18, vertical: 4),
                  child: Text(
                    'Showing the first 100 options. Type more to narrow your search.',
                    style: TextStyle(color: _muted, fontSize: 11),
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
