-- Query to get next 6 weeks from a provider's signup date
create temporary table  numbers AS (
    SELECT 0 AS week_num
    UNION ALL SELECT 1
    UNION ALL SELECT 2
    UNION ALL SELECT 3
    UNION ALL SELECT 4
    UNION ALL SELECT 5
    UNION ALL SELECT 6
    -- can add more than 6 weeks here if wanted
);

create temporary table provider_weeks AS (
    SELECT 
        p.provider_id,
        DATEADD(week, n.week_num, p.signup_dt) AS base_date,
        n.week_num AS week_number
    FROM 
        analytics.onboarding_progress_pros p  
        CROSS JOIN numbers n
    WHERE 
        -- p.provider_id = 2337617  -- Replace with your specific provider_id 
    	p.signup_dt = '2025-03-01'-- between '2025-03-15' and '2025-04-01' -- replace with what signup dates your looking for
);


create temporary table provider_weekly as (
SELECT 
    provider_id,
    week_number,
    base_date AS week_start_date,
    DATEADD(day, 6, base_date) AS week_end_date
FROM 
    provider_weeks
);

create temp table weekly_rev as (
select pw.provider_id, pw.week_number ,count(distinct adf.appointment_id ) apts, sum(pro_net_revenue) net_rev , sum(date_diff('minute', adf.start, adf.end ))apt_min -- * , date_diff('minute', adf.start, adf.end ) apt_min
from provider_weekly pw
join appointments_details_fact adf on  adf.provider_id = pw.provider_id 
	and adf.start between pw.week_start_date and pw.week_end_date 
	and appt_state = 'completed'   -- and booking_type in ('client_user_booking','guest_user_booking')
group by 1,2
);

create temp table weekly_mp as (
select pw.provider_id, pw.week_number
	, count(distinct case when sem.event = 'client_proprofile_viewed' then sem.cookie_id end) profile_views
    , count(distinct case when sem.event = 'client_appointment_booked' then sem.cookie_id end) appointments_booked 
   
from styleseat_events.styleseat_events_master sem
join provider_weekly pw on pw.provider_id = coalesce(sem.provider_id_viewed,sem.provider_id ) and sem.event_date between pw.week_start_date and pw.week_end_date 
where sem.event_date >= '2025-02-01'::date
	and sem.event in ('client_proprofile_viewed','client_appointment_booked') 
group by 1,2
);
create temp table weekly_aau as (
	select pw.provider_id , pw.week_number, unique_visit_days , app_active_user_flag 
	from analytics.app_active_users_daily_change aau
	join provider_weekly pw on pw.provider_id = aau.provider_id and pw.week_end_date = aau.date
);

select pw.*, wr.apts, wr.net_rev,  wr.apt_min, round((wr.net_rev /wr.apt_min *60) ,2)as hourly_rate
	, mp.profile_views, mp.appointments_booked SS_apt_booked , aau.unique_visit_days, aau.app_active_user_flag as is_app_active_user
	, row_number() over (partition by pw.provider_id order by pw.week_number desc) row_num
from provider_weekly pw
left join weekly_rev wr on wr.provider_id = pw.provider_id and pw.week_number = wr.week_number
left join weekly_mp mp on mp.provider_id = pw.provider_id and pw.week_number = mp.week_number
left join weekly_aau aau on aau.provider_id = pw.provider_id and pw.week_number = aau.week_number
where pw.week_end_date <= current_date -- getting ride of future and partial weeks
order by 1,2
