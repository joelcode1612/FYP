import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/features/property_management/domain/entities/provider_models.dart';

/// Loads the workspace from the endpoint the caller is authorized for.
///
/// There is no client-side role filtering: the server decides which rows an
/// account may see, and this method only chooses the transport.
abstract final class ProviderListingsService {
  static Future<ProviderWorkspace> load(AppRole role) async {
    if (role == AppRole.agent) {
      final rows = await ServiceLocator.agentListings.assignedListings();
      return ProviderWorkspace(
        isAgent: true,
        listings: [
          for (final row in rows)
            if (row.raw['property_exists'] != false)
              ProviderListing.fromAssignment(row),
        ],
      );
    }
    final rows = await ServiceLocator.ownerListings.myListings();
    return ProviderWorkspace(
      isAgent: false,
      listings: [for (final row in rows) ProviderListing.fromOwner(row)],
    );
  }
}

