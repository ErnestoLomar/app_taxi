import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'places_service.dart';

class PlaceAutocompleteField extends StatefulWidget {
  final String label;
  final PlacesService places;
  final TextEditingController controller;
  final void Function(String description, String placeId) onSelected;
  final bool enabled;

  // Opcional: sesgo por ubicación
  final double? biasLat;
  final double? biasLng;

  const PlaceAutocompleteField({
    super.key,
    required this.label,
    required this.places,
    required this.controller,
    required this.onSelected,
    this.enabled = true,
    this.biasLat,
    this.biasLng,
  });

  @override
  State<PlaceAutocompleteField> createState() => _PlaceAutocompleteFieldState();
}

class _PlaceAutocompleteFieldState extends State<PlaceAutocompleteField> {
  Timer? _debounce;
  List<PlacePrediction> _items = [];
  bool _loading = false;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      if (!mounted) return;

      if (text.trim().length < 3) {
        setState(() => _items = []);
        return;
      }

      setState(() => _loading = true);
      try {
        final bias = (widget.biasLat != null && widget.biasLng != null)
            ? LatLng(widget.biasLat!, widget.biasLng!)
            : null;

        final results = await widget.places.autocomplete(
          text,
          locationBias: bias,
          radiusMeters: 35000,
        );

        if (!mounted) return;
        setState(() => _items = results);
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  void _selectItem(PlacePrediction p) {
    widget.controller.text = p.description;
    setState(() => _items = []);
    widget.onSelected(p.description, p.placeId);
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          enabled: widget.enabled,
          controller: widget.controller,
          onChanged: _onChanged,
          decoration: InputDecoration(
            labelText: widget.label,
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: _loading
                ? const Padding(
              padding: EdgeInsets.all(10),
              child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            )
                : (widget.controller.text.isEmpty
                ? null
                : IconButton(
              icon: const Icon(Icons.clear),
              onPressed: widget.enabled
                  ? () {
                widget.controller.clear();
                setState(() => _items = []);
              }
                  : null,
            )),
          ),
        ),
        if (_items.isNotEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.black12),
              borderRadius: BorderRadius.circular(10),
              boxShadow: const [BoxShadow(blurRadius: 10, color: Colors.black12, offset: Offset(0, 6))],
            ),
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: _items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final p = _items[i];
                return ListTile(
                  dense: true,
                  title: Text(p.description),
                  onTap: widget.enabled ? () => _selectItem(p) : null,
                );
              },
            ),
          ),
      ],
    );
  }
}