import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/config/mobile_config.dart';
import '../../shell/entrepreneur_tab_scope.dart';
import '../../shell/mobile_app_shell.dart';

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

  static const List<String> _stepNames = <String>[
    'Property details',
    'Location',
    'Photos',
    'Review',
    'Confirmation',
  ];

  static const List<String> _stepDescriptions = <String>[
    'Enter the basic details of your commercial unit.',
    'Add the property address and check the pin position.',
    'Attach photos of the property (JPG, PNG or WebP).',
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
  final TextEditingController _latitudeController = TextEditingController();
  final TextEditingController _longitudeController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();

  int _step = 1;
  String _propertyType = 'Shoplot';
  String? _validationMessage;

  // Server state: the persisted PostgreSQL draft and its lifecycle.
  String? _draftId;
  String _serverStatus = 'draft';
  String? _rejectionReason;
  bool _saving = false;
  bool _submitting = false;
  String? _serverMessage;
  String? _serverError;
  List<OwnerListingPhoto> _photos = const [];
  final Set<int> _uploadingPhotos = <int>{};

  String get _propertyName => _nameController.text.trim();
  String get _monthlyRent => _rentController.text.trim();
  String get _builtUpArea => _areaController.text.trim();
  String get _address => _addressController.text.trim();
  String get _stateName => _stateController.text.trim();
  String get _district => _districtController.text.trim();
  String get _postcode => _postcodeController.text.trim();
  String get _latitude => _latitudeController.text.trim();
  String get _longitude => _longitudeController.text.trim();

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
    _latitudeController.dispose();
    _longitudeController.dispose();
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
    _photos = listing.photos;
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
    text(_descriptionController, listing.description);
    text(_latitudeController,
        listing.latitude == null ? '' : '${listing.latitude}');
    text(_longitudeController,
        listing.longitude == null ? '' : '${listing.longitude}');
    if (listing.propertyType != null && listing.propertyType!.isNotEmpty) {
      _propertyType = listing.propertyType!;
    }
    setState(() {});
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
        latitude: double.tryParse(_latitude),
        longitude: double.tryParse(_longitude),
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
  // Photos
  // ---------------------------------------------------------------------------

  Future<void> _pickAndUploadPhoto() async {
    if (_draftId == null) {
      setState(() {
        _validationMessage =
            'Save the draft first — photos attach to the saved property record.';
      });
      return;
    }
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (picked == null || !mounted) return;
      final bytes = await picked.readAsBytes();
      final Uint8List data = bytes;
      setState(() => _uploadingPhotos.add(-1));
      await ServiceLocator.ownerListings.uploadPhoto(
        listingId: _draftId!,
        filename: picked.name,
        bytes: data,
        contentType: _contentTypeFor(picked.name),
      );
      if (!mounted) return;
      final photos =
          await ServiceLocator.ownerListings.photos(_draftId!);
      if (!mounted) return;
      setState(() {
        _photos = photos;
        _serverMessage = 'Photo uploaded.';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _serverError = _readableError(
          error,
          fallback: 'The photo upload failed. Your draft is saved.',
        );
      });
    } finally {
      if (mounted) setState(() => _uploadingPhotos.clear());
    }
  }

  Future<void> _deletePhoto(OwnerListingPhoto photo) async {
    if (_draftId == null) return;
    try {
      await ServiceLocator.ownerListings.deletePhoto(_draftId!, photo.id);
      if (!mounted) return;
      setState(() {
        _photos = _photos.where((p) => p.id != photo.id).toList();
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _serverError = _readableError(error, fallback: 'Could not remove the photo.');
      });
    }
  }

  Future<void> _makePrimary(OwnerListingPhoto photo) async {
    if (_draftId == null) return;
    try {
      await ServiceLocator.ownerListings.setPrimaryPhoto(_draftId!, photo.id);
      if (!mounted) return;
      final photos = await ServiceLocator.ownerListings.photos(_draftId!);
      if (!mounted) return;
      setState(() => _photos = photos);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _serverError = _readableError(error, fallback: 'Could not set the primary photo.');
      });
    }
  }

  static String _contentTypeFor(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  // ---------------------------------------------------------------------------
  // Step validation + navigation (client-side guard only; the backend is
  // authoritative at submission time)
  // ---------------------------------------------------------------------------

  String _display(String value) => value.isEmpty ? 'Not provided' : value;

  bool _validateCurrentStep() {
    if (!_editable) {
      _validationMessage =
          'This record is awaiting review — its details can no longer be edited.';
      return false;
    }
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
        if (_step == 5 && _live) {
          // Reaching the confirmation step autosaves so the record exists
          // even if the user leaves before pressing either button.
          _saveDraft();
        }
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
          style: const TextStyle(
            color: _muted,
            fontSize: 13,
            height: 1.5,
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
          label: 'City / district',
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
          label: 'Latitude (required for submission)',
          controller: _latitudeController,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true, signed: true),
        ),
        const SizedBox(height: 16),
        _buildTextField(
          label: 'Longitude (required for submission)',
          controller: _longitudeController,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true, signed: true),
        ),
        const SizedBox(height: 15),
        _buildInfoNotice(
          'Coordinates place the property on the Explore map. Valid Malaysian '
          'state and postcode values are checked again when you submit.',
        ),
      ],
    );
  }

  Widget _buildPhotos() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          onTap: _uploadingPhotos.isNotEmpty ? null : _pickAndUploadPhoto,
          borderRadius: BorderRadius.circular(15),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
            decoration: BoxDecoration(
              color: const Color(0xFFF7FAFF),
              border: Border.all(
                color: const Color(0xFFBBD0F3),
                width: 1.5,
              ),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Column(
              children: <Widget>[
                Icon(
                  _uploadingPhotos.isNotEmpty
                      ? Icons.hourglass_top_rounded
                      : Icons.add_photo_alternate_outlined,
                  color: _brandStrong,
                  size: 43,
                ),
                const SizedBox(height: 12),
                Text(
                  _uploadingPhotos.isNotEmpty
                      ? 'Uploading photo…'
                      : 'Add property photos',
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 7),
                const Text(
                  'JPG, PNG or WebP — up to 8 MB each. Photos upload to '
                  'Sitewise storage and attach to the saved draft.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _muted, fontSize: 11, height: 1.5),
                ),
              ],
            ),
          ),
        ),
        if (_photos.isNotEmpty) ...<Widget>[
          const SizedBox(height: 15),
          GridView.builder(
            itemCount: _photos.length,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              mainAxisExtent: 120,
            ),
            itemBuilder: (context, index) {
              final photo = _photos[index];
              return Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: photo.isPrimary
                        ? const Color(0xFF81A8FB)
                        : const Color(0xFFDCE6F3),
                    width: photo.isPrimary ? 1.5 : 1,
                  ),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Column(
                  children: <Widget>[
                    Expanded(
                      child: Image.network(
                        photo.url,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        errorBuilder: (_, _, _) => const Icon(
                          Icons.image_outlined,
                          color: Color(0xFF4D6380),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (photo.isPrimary)
                      const Text(
                        'Primary',
                        style: TextStyle(
                          color: _brandStrong,
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                        ),
                      )
                    else
                      GestureDetector(
                        onTap: () => _makePrimary(photo),
                        child: const Text(
                          'Set primary',
                          style: TextStyle(
                            color: _muted,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    GestureDetector(
                      onTap: () => _deletePhoto(photo),
                      child: const Text(
                        'Remove',
                        style: TextStyle(
                          color: Color(0xFFB91C1C),
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
        const SizedBox(height: 14),
        _buildInfoNotice(
          'Ownership evidence documents are separate: upload them from My '
          'Properties before submitting — at least one is required for '
          'verification, and they stay private.',
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
            _ReviewRow('Property name', _display(_propertyName)),
            _ReviewRow('Property type', _propertyType),
            _ReviewRow('Monthly rent', 'RM $_monthlyRent'),
            _ReviewRow('Built-up area', '$_builtUpArea sq ft'),
          ],
        ),
        const SizedBox(height: 18),
        _buildReviewSection(
          title: 'Location & address',
          step: 2,
          rows: <_ReviewRow>[
            _ReviewRow('Address', _display(_address)),
            _ReviewRow('State', _display(_stateName)),
            _ReviewRow('City / district', _display(_district)),
            _ReviewRow('Postcode', _display(_postcode)),
            _ReviewRow(
              'Coordinates',
              _latitude.isEmpty ? 'Not provided' : '$_latitude, $_longitude',
            ),
          ],
        ),
        const SizedBox(height: 18),
        _buildReviewSection(
          title: 'Photos',
          step: 3,
          rows: <_ReviewRow>[
            _ReviewRow(
              'Attached photos',
              _photos.isEmpty ? 'None yet' : '${_photos.length} photo(s)',
            ),
          ],
        ),
        const SizedBox(height: 16),
        _buildInfoNotice(
          'Review & finish saves the record to Sitewise. Submission for '
          'verification additionally requires complete details and at least '
          'one ownership document.',
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
                    'details, attach photos and ownership evidence, then '
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
              onPressed: () => EntrepreneurTabScope.open(
                context,
                '/entrepreneur/spaces',
              ),
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
            success ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
            color: success ? const Color(0xFF087443) : const Color(0xFF991B1B),
            size: 17,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: success ? const Color(0xFF0A5B36) : const Color(0xFF991B1B),
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
    int maxLines = 1,
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
