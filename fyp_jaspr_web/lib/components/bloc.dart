import 'package:bloc/bloc.dart';
import 'package:jaspr/jaspr.dart';

/// Jaspr counterpart to `flutter_bloc`'s `BlocBuilder`.
///
/// Subscribes to the cubit's [Stream] with the current state seeded as
/// [StreamBuilder.initialData]. On the server (static generation) the stream
/// is `null` — jaspr asserts streams are never attached during SSR — so the
/// server renders one frame of the *current* state and the browser attaches
/// the subscription after hydration, rebuilding on every later emit.
class CubitBuilder<C extends Cubit<S>, S> extends StreamBuilder<S> {
  CubitBuilder({
    required C cubit,
    required Component Function(BuildContext context, S state) builder,
    super.key,
  }) : super(
         stream: kIsWeb ? cubit.stream : null,
         initialData: cubit.state,
         builder: (context, snapshot) => builder(context, snapshot.data as S),
       );
}
