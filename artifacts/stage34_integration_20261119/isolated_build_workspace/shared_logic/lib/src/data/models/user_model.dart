import '../../domain/entities/app_role.dart';
import '../../domain/entities/user.dart';

class UserModel {
  final String id;
  final String name;
  final String email;
  final String role;
  final String status;
  final String location;

  const UserModel({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.status,
    required this.location,
  });

  factory UserModel.fromMap(Map<String, dynamic> map) => UserModel(
    id: '${map['id']}',
    name: '${map['name']}',
    email: '${map['email'] ?? ''}',
    role: '${map['role'] ?? 'entrepreneur'}',
    status: '${map['status'] ?? 'Active'}',
    location: '${map['location'] ?? ''}',
  );

  SitewiseUser toEntity() => SitewiseUser(
    id: id,
    name: name,
    email: email,
    role: AppRole.values.firstWhere(
      (r) => r.name == role,
      orElse: () => AppRole.entrepreneur,
    ),
    status: status,
    location: location,
    joinedAt: DateTime(2024, 1, 1),
  );
}
