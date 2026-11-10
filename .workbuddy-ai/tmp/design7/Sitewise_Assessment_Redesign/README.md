# Sitewise · Location Assessment Workspace (DESIGN.md v7)

This is a standalone, responsive HTML/CSS/JavaScript **frontend reference**, not an installed Jaspr route or a production application. Visual tokens match the uploaded Sitewise `DESIGN(7).md`: `#F4F7FB` paper, `#E8EEF6` muted blue, `#FFFFFF` surfaces, `#1D4ED8` brand actions, `#0B0F19` headings, Archivo with a system fallback, and rounded panels. The dark left Entrepreneur sidebar follows the user's assessment-workspace screenshot; the uploaded `DESIGN.md` primarily describes the public landing page and is used here for shared visual identity.

## Launch

Open `Sitewise_Assessment_Redesigned_Standalone.html` directly in Chrome/Edge, or place `index.html`, `style.css`, and `app.js` together under a local HTTP server.

**To inspect the full flow without an account**, choose **Try illustrative preview** on Stage 1. That mode contains two **explicitly fictional example listings and illustration-only metrics**. It cannot claim those records are actually saved to the user's account. Production and demo modes are kept separate; no demo data silently appears in the live Saved Properties list.

## Five stages

1. **Select Property** — Only authenticated Saved Properties API results are selectable in live mode; empty, loading, error, and missing-API states are distinct.
2. **Business Preferences** — Eight questions, one at a time. Q1–Q5 are the agreed business questions; Q6 customer access mode, Q7 max rent, and Q8 minimum area are clearly marked proposed additions. Target Customers supports multiple selections. Back/Next preserves answers within this browser session.
3. **Location Evidence** — Five categories: population, demand generators, accessibility, parking, competitors. The map uses OpenStreetMap when valid coordinates exist and internet is available. Changing 500m / 1km / 2km / 3km alters map viewport only; it **does not claim** to render accurate polygon buffers or network travel catchments. For accurate rings/isochrones, integrate Leaflet/PostGIS geometries in your real application. No unverified numeric values are shown in live mode.
4. **AI Explanation** — Accepts 47 signed feature SHAP values for the same property ID from an authenticated analysis endpoint. Requires a model identifier and numerically checks base + contributions = model output (tolerance 1e-4). It is separate from questionnaire matching.
5. **Assessment Report** — Browser draft and Print/Save-as-PDF (browser print dialog); it does not save reports to FastAPI/Supabase.

## Production connection

**You must provide the real API routes from your repository**; the HTML does not assume that a particular path is deployed. Put the following configuration script *before* `<script src="app.js"></script>` in `index.html` (or before the inline app script for the standalone copy):

```html
<script>
window.SITEWISE_ASSESSMENT_CONFIG = {
  savedPropertiesEndpoint: '/api/v1/your-existing-saved-properties-route',
  analysisEndpoint: '/api/v1/your-existing-properties/{propertyId}/analysis',
  explanationEndpoint: '/api/v1/your-existing-properties/{propertyId}/shap',
  getAccessToken: async () => {
    // Return the signed-in user's Supabase access JWT using your existing SDK.
    // Do not put secret/service-role keys in frontend code.
    return null;
  }
};
</script>
```

Saved Properties response can be an array, `{items:[...]}`, `{saved_properties:[...]}`, or `{data:[...]}`; items may contain nested `property` objects. Expected property fields include `property_id`, `title`, `state`, `city`, `monthly_rent_myr`, `built_up_area_sqft`, `latitude`, and `longitude`, with common aliases normalized in code.

The analysis response must have a matching `property_id` and `features` or `feature_values` object keyed by the same feature names used in the UI. All values not present are shown as **Unavailable**, never as zero.

Example SHAP response contract (illustrative structure; no real model result is contained here):

```json
{
  "property_id": "YOUR_SAVED_PROPERTY_ID",
  "model_id": "baseline_47",
  "output_scale": "research_p_u_association_score",
  "base_value": 0.0,
  "model_output": 0.0,
  "features": [
    {"name":"FEATURE_1", "category":"Population", "shap_value":0.0}
  ]
}
```

A real response **must contain exactly 47 features**; example above is only a schema illustration. Values must be finite, signed, and additive on the score's scale. Model scores are *not profitability or business success probabilities*.

### Safety and correctness boundaries

- Never rely on a browser property ID to establish saved-property ownership; enforce resource-level access server-side.
- Validate Supabase JWT and roles server-side and keep auth tokens out of static source files.
- Never mix SHAP values from another property or another model with the selected listing.
- Show sample addresses, prices, map pins and numbers as *illustrative* unless verified by real source data.
- Actual map tiles and Archivo web font require external network access; the core UI remains usable offline.
- No code has been edited in the user's repository.
