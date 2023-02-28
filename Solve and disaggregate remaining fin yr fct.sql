DECLARE @ver_cd varchar(99) = 'FEB23FCT1'
DECLARE @ver_key int = (SELECT [Version_Key] FROM Dim_Version WHERE [Version_Code] = @ver_cd)
DECLARE @fct_st_per char(6) = (SELECT [Financial_Period_Start] FROM Dim_Version WHERE [Version_Code] = @ver_cd)
DECLARE @fct_end_per char(6) = SUBSTRING(@fct_st_per,1,4) + '12'
DECLARE @bas_st_per char(6) = (SELECT Financial_Period_Code FROM Dim_Financial_Period WHERE [End_of_Month] = (SELECT EOMONTH([End_of_Month],-12) FROM Dim_Financial_Period WHERE Financial_Period_Code = @fct_st_per))
DECLARE @bas_end_per char(6) = SUBSTRING(@bas_st_per,1,4) + '12'
;

WITH ytd AS
	(
	SELECT
		f.[Product_Key] [Product]
	,	f.[Element_Key] [Element]
	,	SUM([AUD_Fact]) [AUD_Fact]
	FROM
		Fact_Month_Financial_Movement f
		LEFT JOIN Dim_Financial_Period t ON f.Financial_Period_Key = t.Financial_Period_Key
		LEFT JOIN Dim_Version v ON f.Version_Key = v.Version_Key
		LEFT JOIN Dim_Element e ON f.Element_Key = e.Element_Key
	WHERE
		v.[Version_Code] = 'act'
	AND e.[BS/IS] = 'income statement'
	AND t.[Financial_Year] = SUBSTRING(@fct_st_per,1,4)
	AND t.[Financial_Period_Code] < @fct_st_per
	GROUP BY
		f.[Product_Key]
	,	f.[Element_Key]
	)
,ALLOCATABLE_AMT AS
	(
	SELECT
		ISNULL(ful.[Product],ytd.[Product]) [Product]
	,	ISNULL(ful.[Element],ytd.[Element]) [Element]
	,	ISNULL(ful.[AUD_Fact],0) - ISNULL(ytd.[AUD_Fact],0) [AUD_Fact]
	FROM
		Forecast_Input ful
		FULL OUTER JOIN ytd 
			ON	ful.[Product] = ytd.[Product]
			AND ful.[Element] = ytd.[Element]
	)
,ALLOCATION_BASE AS
	(
	SELECT
		f.[Product_Key] [Product]
	,	f.[Element_Key] [Element]
	,	SUM([AUD_Fact]) [AUD_Fact]
	FROM
		Fact_Month_Financial_Movement f
		LEFT JOIN Dim_Financial_Period t ON f.Financial_Period_Key = t.Financial_Period_Key
		LEFT JOIN Dim_Version v ON f.Version_Key = v.Version_Key
		LEFT JOIN Dim_Element e ON f.Element_Key = e.Element_Key
	WHERE
		v.[Version_Code] = 'act'
	AND e.[BS/IS] = 'income statement'
	AND t.[Financial_Period_Code] BETWEEN @bas_st_per AND @bas_end_per
	GROUP BY
		f.[Product_Key]
	,	f.[Element_Key]
	)
,ALLOCATION_RATIO AS
	(
	SELECT
		a_amt.[Product]
	,	a_amt.[Element]
	,	CASE
			WHEN a_bas.[AUD_Fact] = 0 THEN NULL
			ELSE a_amt.[AUD_Fact]/CONVERT(float,a_bas.[AUD_Fact])
		END [Allocation_Ratio]
	FROM
		ALLOCATABLE_AMT a_amt
		LEFT JOIN ALLOCATION_BASE a_bas
			ON	a_amt.[Product] = a_bas.[Product]
			AND a_amt.[Element] = a_bas.[Element]
	)
,allocatedByProportion AS
	(
	SELECT
		@ver_key [Version_Key]
	,	t_plus12.[Financial_Period_Key]
	,	f.[District_Key]
	,	f.[Responsibility_Centre_Key]
	,	f.[Product_Key]
	,	f.[Activity_Key]
	,	f.[Element_Key]
	,	ROUND(SUM(f.[AUD_Fact]) * r.[Allocation_Ratio],2) [AUD_Fact]
	FROM
		Fact_Month_Financial_Movement f
		LEFT JOIN Dim_Financial_Period t ON f.Financial_Period_Key = t.Financial_Period_Key
		LEFT JOIN Dim_Financial_Period t_plus12 ON EOMONTH(t.[End_of_Month],12) = t_plus12.[End_of_Month]
		LEFT JOIN Dim_Version v ON f.Version_Key = v.Version_Key
		LEFT JOIN Dim_Element e ON f.Element_Key = e.Element_Key
		INNER JOIN ALLOCATION_RATIO r
			ON	f.[Product_Key] = r.[Product]
			AND f.[Element_Key] = r.[Element]
	WHERE
		v.[Version_Code] = 'act'
	AND e.[BS/IS] = 'income statement'
	AND t.[Financial_Period_Code] BETWEEN @bas_st_per AND @bas_end_per
	GROUP BY
		t_plus12.[Financial_Period_Key]
	,	f.[District_Key]
	,	f.[Responsibility_Centre_Key]
	,	f.[Product_Key]
	,	f.[Activity_Key]
	,	f.[Element_Key]
	,	r.[Allocation_Ratio]
	)
,eligible AS
	(
	SELECT DISTINCT
		t.[Financial_Period_Key]
	,	d.[District_Key]
	,	r.[Responsibility_Centre_Key]
	,	99 [Activity_Key]
	FROM
		Dim_Financial_Period t
		CROSS JOIN (SELECT District_Key FROM Dim_District) d 
		CROSS JOIN (SELECT Responsibility_Centre_Key FROM Dim_Responsibility_Centre WHERE [Responsibility_Centre_Name] <> 'balance sheet') r
	WHERE
		t.[Financial_Period_Key] BETWEEN @fct_st_per AND @fct_end_per
	)
,numerator AS
	(SELECT
		CONVERT(float,COUNT(*)) [n]
	FROM
		eligible
	)
,allocatedByEligible AS
		(
	SELECT DISTINCT
		@ver_key [Version_Key]
	,	elig.[Financial_Period_Key]
	,	elig.[District_Key]
	,	elig.[Responsibility_Centre_Key]
	,	a_amt.[Product] [Product_Key]
	,	elig.[Activity_Key]
	,	a_amt.[Element] [Element_Key]
	,	ROUND(a_amt.[AUD_Fact]/numerator.n,2) [AUD_Fact]
	FROM
		ALLOCATABLE_AMT a_amt
		LEFT JOIN ALLOCATION_RATIO r
			ON	a_amt.[Product] = r.[Product]
			AND a_amt.[Element] = r.[Element]
		CROSS JOIN eligible elig
		CROSS JOIN numerator
	WHERE
		r.Allocation_Ratio IS NULL
	)

SELECT * FROM allocatedByEligible
UNION
SELECT * FROM allocatedByProportion
