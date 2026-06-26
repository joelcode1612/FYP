const map = L.map("map").setView([3.0738, 101.6077], 12);

L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
  maxZoom: 19,
}).addTo(map);

document.getElementById("loadBtn").addEventListener("click", loadBusinesses);

async function loadBusinesses() {
  const response = await fetch("/api/businesses");

  const data = await response.json();

  console.log(data);

  data.forEach((b) => {
    const lat = parseFloat(b.latitude || b.Latitude);

    const lng = parseFloat(b.longitude || b.Longitude);

    if (isNaN(lat) || isNaN(lng)) {
      return;
    }

    const rating = b.rating || b.Rating || "N/A";

    const reviews = b.review_count || b.Reviews || "N/A";

    L.marker([lat, lng])

      .addTo(map).bindPopup(`
            <b>${b.name || b.Name}</b>
            <br>
            Rating: ${rating}
            <br>
            Reviews: ${reviews}
        `);
  });
}
