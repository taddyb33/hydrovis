SELECT
    max_forecast.feature_id,
    max_forecast.maxflow_48hour_cms AS streamflow_cms
FROM cache.max_flows_srf_hi max_forecast
JOIN derived.recurrence_flows_hi rf ON rf.feature_id=max_forecast.feature_id
WHERE 
    max_forecast.maxflow_48hour_cfs >= rf.high_water_threshold AND 
    rf.high_water_threshold > 0::double precision