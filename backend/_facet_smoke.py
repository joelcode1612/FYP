import json, time
from sqlmodel import Session
from sitewise.db.analytics_session import analytics_engine
from sitewise.services.recommendation_search_service import (
    RecommendationSearchService, SearchCriteria)

t0 = time.time()
with Session(analytics_engine) as s:
    svc = RecommendationSearchService(s)
    browse = svc.facets()
    print("variant", __import__("sitewise.core.config", fromlist=["Settings"]).Settings().pu_model_variant)
    print("universe", browse["universe_total"], "matching", browse["matching_total"], "states", browse["states"][:4])
    print("budget options", len(browse["rental_ranges"]["options"]))
    for o in browse["rental_ranges"]["options"]: print("  ", o)
    print("size options")
    for o in browse["size_ranges"]["options"]: print("  ", o)
    print("elapsed %.2fs" % (time.time()-t0))
    t1=time.time()
    johor = SearchCriteria(preferred_state="Johor")
    f2 = svc.facets(johor)
    print("johor matching", f2["matching_total"], "states", f2["states"][:6])
    print("johor budget", [ (o["label"], o["total"]) for o in f2["rental_ranges"]["options"]])
    print("elapsed %.2fs" % (time.time()-t1))
    print("search total johor", svc.search(SearchCriteria(preferred_state="Johor", page_size=1))["pagination"]["total"])
