// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'pipeline.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$PipelineEvent {

 Object get field0;



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PipelineEvent&&const DeepCollectionEquality().equals(other.field0, field0));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(field0));

@override
String toString() {
  return 'PipelineEvent(field0: $field0)';
}


}

/// @nodoc
class $PipelineEventCopyWith<$Res>  {
$PipelineEventCopyWith(PipelineEvent _, $Res Function(PipelineEvent) __);
}


/// Adds pattern-matching-related methods to [PipelineEvent].
extension PipelineEventPatterns on PipelineEvent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( PipelineEvent_Progress value)?  progress,TResult Function( PipelineEvent_Complete value)?  complete,required TResult orElse(),}){
final _that = this;
switch (_that) {
case PipelineEvent_Progress() when progress != null:
return progress(_that);case PipelineEvent_Complete() when complete != null:
return complete(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( PipelineEvent_Progress value)  progress,required TResult Function( PipelineEvent_Complete value)  complete,}){
final _that = this;
switch (_that) {
case PipelineEvent_Progress():
return progress(_that);case PipelineEvent_Complete():
return complete(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( PipelineEvent_Progress value)?  progress,TResult? Function( PipelineEvent_Complete value)?  complete,}){
final _that = this;
switch (_that) {
case PipelineEvent_Progress() when progress != null:
return progress(_that);case PipelineEvent_Complete() when complete != null:
return complete(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String field0)?  progress,TResult Function( PipelineResult field0)?  complete,required TResult orElse(),}) {final _that = this;
switch (_that) {
case PipelineEvent_Progress() when progress != null:
return progress(_that.field0);case PipelineEvent_Complete() when complete != null:
return complete(_that.field0);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String field0)  progress,required TResult Function( PipelineResult field0)  complete,}) {final _that = this;
switch (_that) {
case PipelineEvent_Progress():
return progress(_that.field0);case PipelineEvent_Complete():
return complete(_that.field0);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String field0)?  progress,TResult? Function( PipelineResult field0)?  complete,}) {final _that = this;
switch (_that) {
case PipelineEvent_Progress() when progress != null:
return progress(_that.field0);case PipelineEvent_Complete() when complete != null:
return complete(_that.field0);case _:
  return null;

}
}

}

/// @nodoc


class PipelineEvent_Progress extends PipelineEvent {
  const PipelineEvent_Progress(this.field0): super._();
  

@override final  String field0;

/// Create a copy of PipelineEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PipelineEvent_ProgressCopyWith<PipelineEvent_Progress> get copyWith => _$PipelineEvent_ProgressCopyWithImpl<PipelineEvent_Progress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PipelineEvent_Progress&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'PipelineEvent.progress(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $PipelineEvent_ProgressCopyWith<$Res> implements $PipelineEventCopyWith<$Res> {
  factory $PipelineEvent_ProgressCopyWith(PipelineEvent_Progress value, $Res Function(PipelineEvent_Progress) _then) = _$PipelineEvent_ProgressCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$PipelineEvent_ProgressCopyWithImpl<$Res>
    implements $PipelineEvent_ProgressCopyWith<$Res> {
  _$PipelineEvent_ProgressCopyWithImpl(this._self, this._then);

  final PipelineEvent_Progress _self;
  final $Res Function(PipelineEvent_Progress) _then;

/// Create a copy of PipelineEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(PipelineEvent_Progress(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class PipelineEvent_Complete extends PipelineEvent {
  const PipelineEvent_Complete(this.field0): super._();
  

@override final  PipelineResult field0;

/// Create a copy of PipelineEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PipelineEvent_CompleteCopyWith<PipelineEvent_Complete> get copyWith => _$PipelineEvent_CompleteCopyWithImpl<PipelineEvent_Complete>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PipelineEvent_Complete&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'PipelineEvent.complete(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $PipelineEvent_CompleteCopyWith<$Res> implements $PipelineEventCopyWith<$Res> {
  factory $PipelineEvent_CompleteCopyWith(PipelineEvent_Complete value, $Res Function(PipelineEvent_Complete) _then) = _$PipelineEvent_CompleteCopyWithImpl;
@useResult
$Res call({
 PipelineResult field0
});




}
/// @nodoc
class _$PipelineEvent_CompleteCopyWithImpl<$Res>
    implements $PipelineEvent_CompleteCopyWith<$Res> {
  _$PipelineEvent_CompleteCopyWithImpl(this._self, this._then);

  final PipelineEvent_Complete _self;
  final $Res Function(PipelineEvent_Complete) _then;

/// Create a copy of PipelineEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(PipelineEvent_Complete(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as PipelineResult,
  ));
}


}

// dart format on
