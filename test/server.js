const express = require("express");
const cors = require("cors");
const csv = require("csv-parser");
const fs = require("fs");

const app = express();

app.use(cors());
app.use(express.static("public"));

let businesses = [];

function loadCSV() {
  businesses = [];

  fs.createReadStream("./data/businesses.csv")
    .pipe(csv())
    .on("data", (row) => {
      businesses.push(row);
    })
    .on("end", () => {
      console.log(`Loaded ${businesses.length} businesses`);
    });
}

loadCSV();

app.get("/api/businesses", (req, res) => {
  res.json(businesses);
});

app.get("/api/businesses/filter", (req, res) => {
  const minRating = Number(req.query.minRating || 0);

  const minReviews = Number(req.query.minReviews || 0);

  const result = businesses.filter((b) => {
    const rating = parseFloat(b.rating || b.Rating || 0);

    const reviews = parseInt(b.review_count || b.Reviews || 0);

    return rating >= minRating && reviews >= minReviews;
  });

  res.json(result);
});

app.get("/api/businesses/nearby", (req, res) => {
  const lat = Number(req.query.lat);

  const lng = Number(req.query.lng);

  const radius = Number(req.query.radius || 1000);

  const nearby = [];

  businesses.forEach((b) => {
    const businessLat = parseFloat(b.latitude || b.Latitude);

    const businessLng = parseFloat(b.longitude || b.Longitude);

    if (isNaN(businessLat) || isNaN(businessLng)) {
      return;
    }

    const distance = haversine(lat, lng, businessLat, businessLng);

    if (distance <= radius) {
      nearby.push({
        ...b,
        distance,
      });
    }
  });

  res.json({
    competitors: nearby.length,
    businesses: nearby,
  });
});

function haversine(lat1, lon1, lat2, lon2) {
  const R = 6371000;

  const dLat = ((lat2 - lat1) * Math.PI) / 180;

  const dLon = ((lon2 - lon1) * Math.PI) / 180;

  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos((lat1 * Math.PI) / 180) *
      Math.cos((lat2 * Math.PI) / 180) *
      Math.sin(dLon / 2) *
      Math.sin(dLon / 2);

  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));

  return R * c;
}

app.listen(3000, () => {
  console.log("Server running at http://localhost:3000");
});
