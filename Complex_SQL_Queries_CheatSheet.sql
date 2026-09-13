-- ==============================================================================
-- HOSPITAL MANAGEMENT SYSTEM (MIS) - 10 ADVANCED T-SQL QUERIES
-- Features: Multi-Table Joins, Aggregations, Date/Time Functions, CTEs, Window Functions
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- QUERY 1: Monthly Departmental Revenue & Visit Aggregation
-- Aggregates total revenue, distinct patient visits, and average invoice value 
-- for the last 30 days using DATEADD and DATEDIFF.
-- ------------------------------------------------------------------------------
SELECT 
    d.DepartmentName,
    COUNT(DISTINCT v.VisitID) AS TotalVisits,
    COUNT(DISTINCT v.UHID) AS UniquePatients,
    SUM(b.InvoiceAmount) AS GrossRevenue,
    ROUND(AVG(b.InvoiceAmount), 2) AS AvgInvoiceValue
FROM Departments d
INNER JOIN Visits v ON d.DepartmentID = v.DepartmentID
INNER JOIN Billing b ON v.VisitID = b.VisitID
WHERE b.BillingDate >= DATEADD(month, -1, GETDATE())
  AND b.PaymentStatus = 'Paid'
GROUP BY d.DepartmentName
ORDER BY GrossRevenue DESC;


-- ------------------------------------------------------------------------------
-- QUERY 2: ICU vs. Ward Daily Visitor Scan Count Audit
-- Joins patient, ward, and scan logs to filter patients exceeding daily scan limits.
-- Uses CAST/CONVERT to isolate dates and DATEADD to analyze 7-day windows.
-- ------------------------------------------------------------------------------
SELECT 
    p.UHID,
    p.PatientName,
    w.WardType,
    w.BedNumber,
    CAST(vl.ScanTime AS DATE) AS ScanDate,
    COUNT(vl.LogID) AS TotalDailyScans
FROM Patients p
INNER JOIN Admissions a ON p.UHID = a.UHID
INNER JOIN Wards w ON a.WardID = w.WardID
INNER JOIN VisitorLogs vl ON p.UHID = vl.UHID
WHERE vl.ScanTime >= DATEADD(day, -7, GETDATE())
GROUP BY p.UHID, p.PatientName, w.WardType, w.BedNumber, CAST(vl.ScanTime AS DATE)
HAVING (w.WardType = 'ICU' AND COUNT(vl.LogID) > 2)
    OR (w.WardType = 'General' AND COUNT(vl.LogID) > 4)
ORDER BY ScanDate DESC, TotalDailyScans DESC;


-- ------------------------------------------------------------------------------
-- QUERY 3: Doctor Consultation & Tariff Performance Summary
-- Multi-table join across Doctors, Visits, Services, and Tariffs to evaluate 
-- consultant billings within a custom date window.
-- ------------------------------------------------------------------------------
SELECT 
    doc.DoctorID,
    CONCAT(doc.FirstName, ' ', doc.LastName) AS DoctorName,
    s.ServiceName,
    COUNT(v.VisitID) AS TotalConsultations,
    SUM(t.BaseRate) AS StandardRevenue,
    SUM(b.FinalAmount) AS RealizedRevenue
FROM Doctors doc
INNER JOIN Visits v ON doc.DoctorID = v.DoctorID
INNER JOIN ServiceRendered sr ON v.VisitID = sr.VisitID
INNER JOIN Services s ON sr.ServiceID = s.ServiceID
INNER JOIN TariffPlans t ON s.ServiceID = t.ServiceID AND v.TariffID = t.TariffID
INNER JOIN Billing b ON v.VisitID = b.VisitID
WHERE v.VisitDate BETWEEN DATEADD(day, -30, GETDATE()) AND GETDATE()
GROUP BY doc.DoctorID, doc.FirstName, doc.LastName, s.ServiceName
ORDER BY RealizedRevenue DESC;


-- ------------------------------------------------------------------------------
-- QUERY 4: Average Length of Stay (ALOS) & Discharge Delay Analysis
-- Uses DATEDIFF to calculate admitted days versus expected clearance times.
-- ------------------------------------------------------------------------------
SELECT 
    d.DepartmentName,
    COUNT(a.AdmissionID) AS TotalDischarges,
    AVG(DATEDIFF(day, a.AdmissionDate, a.DischargeDate)) AS AvgStayDays,
    MAX(DATEDIFF(day, a.AdmissionDate, a.DischargeDate)) AS MaxStayDays
FROM Admissions a
INNER JOIN Wards w ON a.WardID = w.WardID
INNER JOIN Departments d ON w.DepartmentID = d.DepartmentID
WHERE a.DischargeDate IS NOT NULL
  AND a.DischargeDate >= DATEADD(month, -3, GETDATE())
GROUP BY d.DepartmentName
ORDER BY AvgStayDays DESC;


-- ------------------------------------------------------------------------------
-- QUERY 5: Outstanding Insurance Claim Balance Breakdown
-- Identifies unpaid claims joined across Patients, TPA Insurance, and Invoices.
-- ------------------------------------------------------------------------------
SELECT 
    tpa.TPAName,
    p.UHID,
    p.PatientName,
    b.InvoiceID,
    b.InvoiceAmount,
    b.ClaimedAmount,
    (b.InvoiceAmount - b.ClaimedAmount) AS PendingBalance,
    DATEDIFF(day, b.BillingDate, GETDATE()) AS DaysPending
FROM Billing b
INNER JOIN Visits v ON b.VisitID = v.VisitID
INNER JOIN Patients p ON v.UHID = p.UHID
INNER JOIN TPACoverage tpa ON v.TPAID = tpa.TPAID
WHERE b.PaymentStatus = 'Pending_Insurance'
  AND b.BillingDate <= DATEADD(day, -15, GETDATE())
ORDER BY DaysPending DESC, PendingBalance DESC;


-- ------------------------------------------------------------------------------
-- QUERY 6: Top Requested Lab Tests & Emergency Turnaround Time
-- Joins Lab Requests, Samples, and Results to track emergency processing speed.
-- ------------------------------------------------------------------------------
SELECT 
    lt.TestName,
    COUNT(lr.RequestID) AS TotalRequested,
    AVG(DATEDIFF(minute, lr.RequestedTime, lr.ResultTime)) AS AvgTurnaroundMinutes
FROM LabRequests lr
INNER JOIN LabTests lt ON lr.TestID = lt.TestID
INNER JOIN Visits v ON lr.VisitID = v.VisitID
WHERE v.VisitType = 'Emergency'
  AND lr.RequestedTime >= DATEADD(day, -14, GETDATE())
GROUP BY lt.TestName
HAVING COUNT(lr.RequestID) >= 5
ORDER BY TotalRequested DESC, AvgTurnaroundMinutes ASC;


-- ------------------------------------------------------------------------------
-- QUERY 7: Pharmacy Inventory Reorder & Expiry Alert
-- Subquery-based joins to flag medicines expiring in the next 60 days.
-- ------------------------------------------------------------------------------
SELECT 
    m.MedicineID,
    m.MedicineName,
    s.SupplierName,
    i.StockQuantity,
    i.ExpiryDate,
    DATEDIFF(day, GETDATE(), i.ExpiryDate) AS DaysToExpiry
FROM Inventory i
INNER JOIN Medicines m ON i.MedicineID = m.MedicineID
INNER JOIN Suppliers s ON i.SupplierID = s.SupplierID
WHERE i.ExpiryDate BETWEEN GETDATE() AND DATEADD(day, 60, GETDATE())
  OR i.StockQuantity < i.ReorderLevel
ORDER BY i.ExpiryDate ASC, i.StockQuantity ASC;


-- ------------------------------------------------------------------------------
-- QUERY 8: Patient Readmission Rate Within 30 Days (Window Function)
-- Tracks readmissions by using LAG() to compute day intervals between admissions.
-- ------------------------------------------------------------------------------
WITH PatientHistory AS (
    SELECT 
        UHID,
        AdmissionID,
        AdmissionDate,
        LAG(AdmissionDate) OVER (PARTITION BY UHID ORDER BY AdmissionDate) AS PreviousAdmission
    FROM Admissions
)
SELECT 
    p.UHID,
    p.PatientName,
    ph.AdmissionDate AS CurrentAdmission,
    ph.PreviousAdmission,
    DATEDIFF(day, ph.PreviousAdmission, ph.AdmissionDate) AS DaysBetweenVisits
FROM PatientHistory ph
INNER JOIN Patients p ON ph.UHID = p.UHID
WHERE ph.PreviousAdmission IS NOT NULL
  AND DATEDIFF(day, ph.PreviousAdmission, ph.AdmissionDate) <= 30
ORDER BY DaysBetweenVisits ASC;


-- ------------------------------------------------------------------------------
-- QUERY 9: Patient Feedback Score vs Doctor Consultation Hours
-- Aggregates ratings by doctor to isolate quality metrics for outpatient care.
-- ------------------------------------------------------------------------------
SELECT 
    doc.DoctorID,
    CONCAT(doc.FirstName, ' ', doc.LastName) AS DoctorName,
    d.DepartmentName,
    COUNT(pf.FeedbackID) AS TotalReviews,
    ROUND(AVG(CAST(pf.Rating AS FLOAT)), 2) AS AverageRating
FROM DoctorFeedback pf
INNER JOIN Visits v ON pf.VisitID = v.VisitID
INNER JOIN Doctors doc ON v.DoctorID = doc.DoctorID
INNER JOIN Departments d ON doc.DepartmentID = d.DepartmentID
WHERE v.VisitDate >= DATEADD(month, -6, GETDATE())
GROUP BY doc.DoctorID, doc.FirstName, doc.LastName, d.DepartmentName
HAVING COUNT(pf.FeedbackID) >= 10
ORDER BY AverageRating DESC;


-- ------------------------------------------------------------------------------
-- QUERY 10: Peak Hourly Emergency Admission Breakdown
-- Extracts hour components to identify hospital staffing demands during peak hours.
-- ------------------------------------------------------------------------------
SELECT 
    DATEPART(hour, v.VisitDate) AS HourOfDay,
    COUNT(v.VisitID) AS EmergencyArrivals,
    SUM(CASE WHEN a.AdmissionID IS NOT NULL THEN 1 ELSE 0 END) AS AdmittedToWard
FROM Visits v
LEFT JOIN Admissions a ON v.VisitID = a.VisitID
WHERE v.VisitType = 'Emergency'
  AND v.VisitDate >= DATEADD(day, -30, GETDATE())
GROUP BY DATEPART(hour, v.VisitDate)
ORDER BY HourOfDay ASC;