-- Query to get next 22 weeks from a provider's signup date
create temporary table  numbers AS (
    SELECT 0 AS week_num
    UNION ALL SELECT 1
    UNION ALL SELECT 2
    UNION ALL SELECT 3
    UNION ALL SELECT 4
    UNION ALL SELECT 5
    UNION ALL SELECT 6
    UNION ALL SELECT 6
    UNION ALL SELECT 7
    UNION ALL SELECT 8
    UNION ALL SELECT 9
    UNION ALL SELECT 10
    UNION ALL SELECT 11
    UNION ALL SELECT 12
    UNION ALL SELECT 13
    UNION ALL SELECT 14
    UNION ALL SELECT 15
    UNION ALL SELECT 16
    UNION ALL SELECT 17
    UNION ALL SELECT 18
    UNION ALL SELECT 19
    UNION ALL SELECT 20
    UNION ALL SELECT 21
    UNION ALL SELECT 22
    -- can add more  here if wanted
);

create temp table first_sub_invoice as (
select sif.provider_id
	, min(sif.subscription_invoice_paid_date ):: date first_sub_payment
from subscriptions_invoice_fact sif
where  is_refunded = 0
and stripe_charge_status = 1
and invoice_paid_status = 1
group by 1
having first_sub_payment >= '2025-03-01'
);


create temporary table provider_weeks AS (
    SELECT 
        p.provider_id,
        -- DATEADD(week, n.week_num, p.first_sub_payment) AS base_date,
        -- shift all pros to same week cycle if needed
        --DATEADD(week, n.week_num, DATE_TRUNC('week', p.first_sub_payment) + INTERVAL '6 days') AS base_date, -- week starts on sunday
        DATEADD(week, n.week_num, DATE_TRUNC('week', p.first_sub_payment)) AS base_date, -- week starts on monday
        n.week_num AS week_number
    FROM 
        first_sub_invoice p  
        CROSS JOIN numbers n
    WHERE 
        -- p.provider_id = 2337617  -- Replace with your specific provider_id 
    	p.first_sub_payment > '2025-02-01'::date  -- between '2025-03-15' and '2025-04-01' -- replace with what subscription dates your looking for  		
);
/*
drop table provider_weeks
select * from provider_weeks
*/

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
/*
select pw.*, wr.apts, wr.net_rev,  wr.apt_min, case when wr.apt_min = 0 then 0 else round((wr.net_rev /wr.apt_min *60) ,2) end as hourly_rate
	, mp.profile_views, mp.appointments_booked SS_apt_booked , aau.unique_visit_days, aau.app_active_user_flag as is_app_active_user
	, row_number() over (partition by pw.provider_id order by pw.week_number desc) row_num
from provider_weekly pw
left join weekly_rev wr on wr.provider_id = pw.provider_id and pw.week_number = wr.week_number
left join weekly_mp mp on mp.provider_id = pw.provider_id and pw.week_number = mp.week_number
left join weekly_aau aau on aau.provider_id = pw.provider_id and pw.week_number = aau.week_number
where pw.week_end_date <= current_date -- getting ride of future and partial weeks

	and pw.provider_id ='805365'

order by 1,2

*/

with base_data as (
    select 
        pw.provider_id,
        pw.week_number,
        pw.week_start_date,
        pw.week_end_date,
        wr.apts, 
        wr.net_rev,  
        wr.apt_min, 
        case when wr.apt_min = 0 then 0 else round((wr.net_rev /wr.apt_min *60) ,2) end as hourly_rate,
        mp.profile_views,
        mp.appointments_booked as SS_apt_booked,
        aau.unique_visit_days, 
        aau.app_active_user_flag as is_app_active_user,
        fps.Pro_profile_pmm_segmentation,
        row_number() over (partition by pw.provider_id order by pw.week_number desc) as row_num
    from provider_weekly pw
    left join weekly_rev wr on wr.provider_id = pw.provider_id and pw.week_number = wr.week_number
    left join weekly_mp mp on mp.provider_id = pw.provider_id and pw.week_number = mp.week_number
    left join weekly_aau aau on aau.provider_id = pw.provider_id and pw.week_number = aau.week_number
    left join dw_analytics.fct_pro_segmentation fps on fps.provider_id = pw.provider_id and fps.as_of_date = pw.week_end_date
    where pw.week_end_date <= current_date -- getting rid of future and partial weeks
),
profile_views_past_weeks as (
    select 
        provider_id,
        sum(case when row_num = 2 then profile_views else 0 end) as profile_views_week_2,
        sum(case when row_num = 3 then profile_views else 0 end) as profile_views_week_3,
        sum(case when row_num in (2, 3) then profile_views else 0 end) as profile_views_past_2_weeks_total
    from base_data
    where row_num in (2, 3) -- weeks 2 and 3 most recent (past 2 weeks)
    group by provider_id
)
select 
    bd.*,
    coalesce(pv.profile_views_week_2, 0) as profile_views_week_2,
    coalesce(pv.profile_views_week_3, 0) as profile_views_week_3,
    coalesce(pv.profile_views_past_2_weeks_total, 0) as profile_views_past_2_weeks_total
from base_data bd
left join profile_views_past_weeks pv on bd.provider_id = pv.provider_id
where bd.row_num = 1 -- only most recent week
order by bd.provider_id;
