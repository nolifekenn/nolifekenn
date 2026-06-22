-- Create a Staging Table
CREATE TABLE walmart_staging
LIKE walmart_sales;

INSERT INTO walmart_staging
SELECT *
FROM walmart_sales
;

SELECT *
FROM walmart_staging
;

-- Check for Impossible Values in Holiday_Flag column.
SELECT * 
FROM walmart_staging
WHERE Holiday_Flag > 1
;

-- Check for duplicate rows.
WITH find_duplicate AS 
(
SELECT *,
	ROW_NUMBER() OVER(PARTITION BY Store, `Date`, Weekly_Sales, Holiday_Flag, Temperature, Fuel_Price, CPI, Unemployment) as row_num
FROM walmart_staging
)
SELECT *
FROM find_duplicate
WHERE row_num > 1
;

-- Standardize the date format from DD-MM-YYYY to walmart_salesYYYY-MM-DD
SELECT `Date`, STR_TO_DATE(`Date`, '%d-%m-%Y') standardized_date
FROM walmart_sales
;

UPDATE walmart_staging
SET `Date` = STR_TO_DATE(`Date`, '%d-%m-%Y')
;

ALTER TABLE walmart_staging
MODIFY COLUMN `Date` DATE;

-- Standardize the decimal format for Weekly_Sales, Fuel Price, CPI, Unemployment
-- Change data type of Holiday_Flag to TINYINT(1)
ALTER TABLE walmart_staging
MODIFY COLUMN Weekly_Sales DECIMAL(12, 2), 
MODIFY COLUMN Fuel_Price DECIMAL(10, 3), 
MODIFY COLUMN CPI DECIMAL(10, 4),
MODIFY COLUMN Unemployment DECIMAL(10, 3),
MODIFY COLUMN Holiday_Flag TINYINT(1)
;

# EDA
-- Sales Performance Metrics
-- Total Gross Revenue
SELECT SUM(Weekly_Sales)
FROM walmart_staging
;
-- Average Weekly Sales per Store
WITH weekly_totals AS 
(
-- Group ALL data by actual calendar weeks and sum the sales
SELECT Store,
	YEARWEEK(`Date`, 1) AS calendar_week,
    SUM(Weekly_Sales) AS total_sales_weekly
FROM walmart_staging
GROUP BY Store, YEARWEEK(`Date`, 1)
)
-- Find the average of those weekly buckets
SELECT Store,
	ROUND(AVG(total_sales_weekly), 2) AS avg_weekly_sales
FROM weekly_totals
GROUP BY Store
;

# TOP 5 and BOTTOM 5 Performing Stores 
WITH store_averages AS 
(
-- Calculate the average for all stores. 
SELECT
	Store, 
	ROUND(AVG(Weekly_Sales), 2) as avg_weekly_sales
FROM walmart_staging
GROUP BY Store
),
ranked_stores AS 
(
-- Assign a top tank and a bottom rank to every store
SELECT
	Store,
    avg_weekly_sales,
	DENSE_RANK() OVER(ORDER BY avg_weekly_sales DESC) rank_top,
    DENSE_RANK() OVER(ORDER BY avg_weekly_sales ASC) rank_bottom
FROM store_averages
)
-- Top 5
SELECT
	Store, 
	avg_weekly_sales,
    'Top Performer',
    rank_top Ranking
FROM ranked_stores
WHERE rank_top <= 5
ORDER BY Ranking ASC
;
-- Bottom 5
WITH store_averages AS 
(
-- Calculate the average for all stores. 
SELECT
	Store, 
	ROUND(AVG(Weekly_Sales), 2) as avg_weekly_sales
FROM walmart_staging
GROUP BY Store
),
ranked_stores AS 
(
-- Assign a top tank and a bottom rank to every store
SELECT
	Store,
    avg_weekly_sales,
	DENSE_RANK() OVER(ORDER BY avg_weekly_sales DESC) rank_top,
    DENSE_RANK() OVER(ORDER BY avg_weekly_sales ASC) rank_bottom
FROM store_averages
)
SELECT
	Store,
	avg_weekly_sales,
    'Bottom Performer',
    rank_bottom Ranking
FROM ranked_stores
WHERE rank_bottom <= 5
ORDER BY Ranking
;

# Temporal and Seasonal Trends
-- Holiday Impact 
SELECT
	ROUND(AVG(CASE WHEN Holiday_Flag = 1 THEN Weekly_Sales END), 2) AS avg_holiday_sales,
    ROUND(AVG(CASE WHEN Holiday_Flag = 0 THEN Weekly_Sales END), 2) AS avg_non_holiday_sales,
-- Calculate the percentage lift ((Holiday - NonHoliday)/ NonHoliday) * 100
	ROUND(
		(AVG(CASE WHEN Holiday_Flag = 1 THEN Weekly_Sales END) -
        AVG(CASE WHEN Holiday_Flag = 0 THEN Weekly_Sales END)) / 
        AVG(CASE WHEN Holiday_Flag = 0 THEN Weekly_Sales END) * 100, 
        2) AS holiday_lift_percentage
FROM walmart_staging
;

-- Month-over-Month (MoM) Growth & Seasonal Peaks
WITH monthly_sales AS 
(
-- Bucket all sales into standard calendar months
SELECT 
	DATE_FORMAT(`Date`, '%Y-%m') AS calendar_month,
    MONTH(`Date`) AS month_number, 
    SUM(Weekly_Sales) AS total_monthly_sales
FROM walmart_staging
GROUP BY DATE_FORMAT(`Date`, '%Y-%m'), MONTH(`Date`)
)
SELECT 
	calendar_month, 
    month_number,
    total_monthly_sales,
    LAG(total_monthly_sales) OVER (ORDER BY calendar_month) AS previous_month_sales,
    -- Calculate MoM Growth Percentage
    ROUND(
		((total_monthly_sales - LAG(total_monthly_sales) OVER (ORDER BY calendar_month))
        / LAG(total_monthly_sales) OVER (ORDER BY calendar_month)) * 100, 2) AS MoM_growth_percentage
FROM monthly_sales
ORDER BY calendar_month ASC
;

-- Year-over-Year (YoY) Growth
WITH YearlyMonthlySales AS 
(
-- Get total sales for every month and year
SELECT 
	YEAR(`Date`) AS sales_year,
    MONTH(`Date`) AS sales_month,
    SUM(Weekly_Sales) AS total_sales
FROM walmart_staging
GROUP BY YEAR(`Date`), MONTH(`Date`)
)
-- Compare a month's sales to the same month in the previous year
SELECT
	sales_year, 
    sales_month,
    total_sales AS current_year_sales,
	LAG(total_sales) OVER (PARTITION BY sales_month ORDER BY sales_year) AS previous_year_sales,
    -- Calculate YoY growth percentage
    ROUND(
		((total_sales - LAG(total_sales) OVER (PARTITION BY sales_month ORDER BY sales_year))
        / LAG(total_sales) OVER (PARTITION BY sales_month ORDER BY sales_year)) * 100, 2)
        AS YoY_growth_percentage
FROM YearlyMonthlySales
ORDER BY sales_year ASC, sales_month ASC
;

# MACROECONOMIC Analysis
-- Sales vs. Unemployment
WITH bracket_summaries AS
(
-- Calculate the core metrics
SELECT
	CASE
		WHEN Unemployment < 6.0 THEN 'Low (< 6%)'
        WHEN Unemployment >= 6.0 AND Unemployment < 8.0 THEN 'Moderate (6% - 7.99%)'
        WHEN Unemployment >= 8.0 AND Unemployment < 10.0 THEN 'High (8% - 9.99%)'
        ELSE 'Very High (10%+)'
	END AS unemployment_bracket,
    COUNT(*) AS weeks_in_bracket, 
    ROUND(AVG(Weekly_Sales), 2) AS avg_weekly_sales,
    SUM(Weekly_Sales) AS total_bracket_sales
FROM walmart_staging
GROUP BY unemployment_bracket
)
-- Calculate the proportional relationship
SELECT
	unemployment_bracket,
    weeks_in_bracket,
    avg_weekly_sales,
    -- What percentage of total time did we spend in this bracket?
    ROUND((weeks_in_bracket / SUM(weeks_in_bracket) OVER ()) * 100, 2) AS pct_of_total_time,
    -- What percentage of total company revenue did this bracket generate?
    ROUND((total_bracket_sales / SUM(total_bracket_sales) OVER ()) * 100, 2) AS pct_of_total_revenue,
    -- Calculate the efficiency ratio (Revenue %(pct) divided by Time %(pct))
    ROUND(
		(total_bracket_sales / SUM(total_bracket_sales) OVER ()) /
        (weeks_in_bracket / SUM(weeks_in_bracket) OVER ()),
        2) AS efficiency_index
FROM bracket_summaries
ORDER BY unemployment_bracket ASC
;

-- Inflation Effect (CPI)
SELECT
	CASE 
		WHEN CPI < 140 THEN 'low CPI (< 140)'
        WHEN CPI >= 140 AND CPI < 170 THEN 'Moderate CPI (140 - 169)'
        WHEN CPI >= 170 AND CPI < 200 THEN 'High CPI (170 - 200)'
        ELSE 'Very High CPI (200+)'
	END AS cpi_bracket,
    COUNT(*) AS total_weeks,
    ROUND(AVG(Weekly_Sales), 2) AS avg_weekly_sales
FROM walmart_staging
GROUP BY cpi_bracket
ORDER BY cpi_bracket ASC
;

-- Fuel Price Sensitivity
WITH fuel_quartiles AS
(
SELECT 
	Store,
	`Date`,
    Weekly_Sales,
    Fuel_Price,
    NTILE(4) OVER (ORDER BY Fuel_Price ASC) AS fuel_price_quartile
FROM walmart_staging
)
SELECT
	fuel_price_quartile,
    ROUND(MIN(Fuel_Price), 2) AS min_gas_price_in_bucket,
    ROUND(MAX(Fuel_Price), 2) AS max_gas_price_in_bucket,
    COUNT(*) AS weeks_in_bucket, 
    ROUND(AVG(Weekly_Sales), 2) AS avg_weekly_sales
FROM fuel_quartiles
GROUP BY fuel_price_quartile
ORDER BY fuel_price_quartile ASC
;
