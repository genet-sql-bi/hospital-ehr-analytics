-- =============================================================
-- Hospital EHR Analytics | 04 Business Analysis
-- -------------------------------------------------------------
-- Each query answers one business question that a dashboard page
-- is built around. Record the result in the "Finding" line, in one
-- sentence with the number, then copy it into the README.
--
--   Section 1  Patient Journey & Clinical Quality   -> Patient Journey page
--   Section 2  Revenue & Bed Capacity               -> Revenue & Capacity page
--   Section 3  Doctor Staffing & Workload           -> Doctor Staffing page
-- =============================================================

USE hospitalehr_db;


-- =============================================================
-- SECTION 1: PATIENT JOURNEY & CLINICAL QUALITY
-- =============================================================

-- Q1: How many patients return (2+ encounters) vs. visit once?
SELECT EncounterCount, COUNT(*) AS PatientCount
FROM (
    SELECT p.PatientID,
           (SELECT COUNT(*) FROM Appointments a  WHERE a.PatientID  = p.PatientID)
         + (SELECT COUNT(*) FROM Admissions   ad WHERE ad.PatientID = p.PatientID) AS EncounterCount
    FROM Patients p
) t
GROUP BY EncounterCount
ORDER BY EncounterCount;
-- Finding: 990 of 1,000 patients had at least one encounter, and 933 (94%) came back
-- 2+ times; the median patient had 5 encounters. Demand is driven by returning patients.


-- Q2: Which diagnoses use the most bed capacity?
--     Average stay alone hides volume, so total bed days is the ranking metric.
SELECT Diagnosis,
       COUNT(*)                      AS Admissions,
       ROUND(AVG(LengthOfStay), 1)   AS AvgLengthOfStay,
       SUM(LengthOfStay)             AS TotalBedDays,
       ROUND(SUM(LengthOfStay) / SUM(SUM(LengthOfStay)) OVER () * 100, 1) AS ShareOfBedDaysPct
FROM Admissions
WHERE LengthOfStay IS NOT NULL          -- completed stays only
GROUP BY Diagnosis
ORDER BY TotalBedDays DESC;
-- Finding: Fracture uses the most bed days (1,077, 28%) through volume, not stay length;
-- Cancer has the longest stay (8.2 days). Fracture, Covid and Cancer = 60% of bed days.


-- Q3: Do diagnoses cluster by hospital?
SELECT h.HospitalName, ad.Diagnosis, COUNT(*) AS Cases
FROM Admissions ad
JOIN Hospitals h ON ad.HospitalID = h.HospitalID
GROUP BY h.HospitalName, ad.Diagnosis
ORDER BY h.HospitalName, Cases DESC;
-- Finding: Diagnoses follow specialty: Hospital 2 (Orthopedics) treats 136 of 195 fractures (70%);
-- Hospitals 1 and 4 (Cardiology) treat 143 of 161 hypertension admissions (89%).


-- Q4: Which tests most often return abnormal results?
--     Sample size is shown so small groups are not over-read.
SELECT TestName,
       COUNT(*)                                   AS TotalTests,
       SUM(IsAbnormalResult)                      AS AbnormalTests,
       ROUND(SUM(IsAbnormalResult) / COUNT(*) * 100, 1) AS AbnormalRatePct
FROM LabTests
GROUP BY TestName
ORDER BY AbnormalRatePct DESC;
-- Finding: MRI (44%), Blood Sugar (43%) and CT (43%) come back abnormal far more often than CBC (31%).
-- Every test has 360+ results, so the gap is not small-sample noise.


-- Q5: Where do outpatients wait longest, relative to consultation time?
--     Appointments has no DepartmentID; department comes from the doctor.
SELECT dep.DepartmentName,
       COUNT(*)                                 AS Appointments,
       ROUND(AVG(a.WaitingTimeMinutes), 1)      AS AvgWaitMin,
       ROUND(AVG(a.ConsultationMinutes), 1)     AS AvgConsultMin,
       ROUND(AVG(a.WaitingTimeMinutes) / AVG(a.ConsultationMinutes), 2) AS WaitToConsultRatio
FROM Appointments a
JOIN Doctors     doc ON doc.DoctorID     = a.DoctorID
JOIN Departments dep ON dep.DepartmentID = doc.DepartmentID
GROUP BY dep.DepartmentName
ORDER BY AvgWaitMin DESC;

-- Overall ratio (the dashboard subtitle) and split by visit type.
-- Completed visits only: No-Show and Cancelled have no wait or consult time.
SELECT VisitType,
       COUNT(*)                                           AS CompletedVisits,
       ROUND(AVG(WaitingTimeMinutes), 1)                  AS AvgWaitMin,
       ROUND(AVG(ConsultationMinutes), 1)                 AS AvgConsultMin,
       ROUND(AVG(WaitingTimeMinutes) / AVG(ConsultationMinutes), 2) AS WaitToConsultRatio
FROM Appointments
WHERE Status = 'Completed'
GROUP BY VisitType
UNION ALL
SELECT 'All visits', COUNT(*),
       ROUND(AVG(WaitingTimeMinutes), 1),
       ROUND(AVG(ConsultationMinutes), 1),
       ROUND(AVG(WaitingTimeMinutes) / AVG(ConsultationMinutes), 2)
FROM Appointments
WHERE Status = 'Completed';
-- Finding: Patients wait 1.5x their consultation overall; follow-ups wait 1.95x their 13-min
-- consult vs 1.2x for new patients. Emergency waits longest (43.5 min); General
-- Medicine is the longest planned-clinic wait (30.2 min) and carries 42% of visits.


-- Q5b: How many booked visits are lost to no-shows and cancellations?
SELECT VisitType,
       COUNT(*)                                        AS BookedVisits,
       ROUND(AVG(Status = 'No-Show')   * 100, 1)       AS NoShowPct,
       ROUND(AVG(Status = 'Cancelled') * 100, 1)       AS CancelledPct
FROM Appointments
GROUP BY VisitType;
-- Finding: 1 in 8 booked slots is lost: 8.2% no-show + 4.0% cancelled. Follow-ups no-show more
-- often than new patients (9.7% vs 6.4%), so reminders should target follow-ups.


-- Q6: How soon after a clinic visit are planned patients admitted?
--     Last completed visit in the SAME department, within 30 days before
--     admission. One row per admission, so no double counting.
WITH LastVisit AS (
    SELECT ad.AdmissionID,
           ad.AdmissionType,
           ad.AdmissionDate,
           MAX(a.AppointmentDate) AS LastVisitDate
    FROM Admissions ad
    JOIN Appointments a   ON a.PatientID = ad.PatientID
                         AND a.Status = 'Completed'
                         AND a.AppointmentDate <= ad.AdmissionDate
                         AND a.AppointmentDate >= ad.AdmissionDate - INTERVAL 30 DAY
    JOIN Doctors      doc ON doc.DoctorID = a.DoctorID
                         AND doc.DepartmentID = ad.DepartmentID
    GROUP BY ad.AdmissionID, ad.AdmissionType, ad.AdmissionDate
)
SELECT ad.AdmissionType,
       COUNT(*)                                                    AS Admissions,
       COUNT(lv.AdmissionID)                                       AS SeenInClinicFirst,
       ROUND(COUNT(lv.AdmissionID) / COUNT(*) * 100, 1)            AS SeenInClinicFirstPct,
       ROUND(AVG(DATEDIFF(lv.AdmissionDate, lv.LastVisitDate)), 1) AS AvgDaysVisitToAdmission
FROM Admissions ad
LEFT JOIN LastVisit lv ON lv.AdmissionID = ad.AdmissionID
GROUP BY ad.AdmissionType;
-- Finding: All 434 planned admissions followed a same-department clinic visit, 6.9 days earlier
-- on average. Only 17% of emergency admissions had a recent clinic visit.


-- Q6b: What share of patients come back within 30 days of discharge?
WITH Ordered AS (
    SELECT AdmissionID, PatientID, Diagnosis, AdmissionDate, DischargeDate,
           LAG(DischargeDate) OVER (PARTITION BY PatientID ORDER BY AdmissionDate) AS PrevDischarge
    FROM Admissions
)
SELECT Diagnosis,
       COUNT(*)                                                         AS Admissions,
       SUM(DATEDIFF(AdmissionDate, PrevDischarge) BETWEEN 0 AND 30)     AS Readmissions30d,
       ROUND(SUM(DATEDIFF(AdmissionDate, PrevDischarge) BETWEEN 0 AND 30)
             / COUNT(*) * 100, 1)                                       AS ReadmissionRatePct
FROM Ordered
GROUP BY Diagnosis
ORDER BY ReadmissionRatePct DESC;
-- Finding: 14.2% of admissions (117 of 825) are 30-day readmissions. Chronic conditions lead:
-- Cancer 21%, Diabetes 20%, Hypertension 20%; Fever only 1%.


-- Q7: Do patients with an abnormal lab result stay longer?
--     LabTests is not linked to a specific admission, so patients are
--     flagged once (any abnormal result). Joining tests directly to
--     admissions would count each stay once per test.
WITH PatientLabFlag AS (
    SELECT PatientID, MAX(IsAbnormalResult) AS HasAbnormal
    FROM LabTests
    GROUP BY PatientID
)
SELECT CASE plf.HasAbnormal WHEN 1 THEN 'Any abnormal result' ELSE 'All results normal' END AS LabGroup,
       COUNT(DISTINCT ad.PatientID)  AS Patients,
       COUNT(*)                      AS Admissions,
       ROUND(AVG(ad.LengthOfStay), 1) AS AvgLengthOfStay
FROM PatientLabFlag plf
JOIN Admissions ad ON ad.PatientID = plf.PatientID
GROUP BY plf.HasAbnormal;
-- Finding: Patients with any abnormal lab stay 4.8 days vs 4.0 days (+20%). Patient-level
-- association only; tests are not linked to a specific stay.


-- =============================================================
-- SECTION 2: REVENUE & BED CAPACITY
-- =============================================================

-- Q8: Which hospital and department generate the most revenue?
SELECT h.HospitalName, dep.DepartmentName,
       COUNT(*)              AS Bills,
       SUM(b.TotalAmount)    AS TotalRevenue,
       ROUND(AVG(b.TotalAmount), 2) AS AvgBill
FROM Billing b
JOIN Admissions  ad  ON b.AdmissionID   = ad.AdmissionID
JOIN Hospitals   h   ON ad.HospitalID   = h.HospitalID
JOIN Departments dep ON ad.DepartmentID = dep.DepartmentID
GROUP BY h.HospitalName, dep.DepartmentName
ORDER BY TotalRevenue DESC;
-- Finding: Hospital 2 Orthopedics is the largest revenue line ($2.96M, 27% of $10.78M total).
-- ICU has the highest average bill (~$54-60K) on very few stays.


-- Q9: How much billing is still pending, and where?
SELECT h.HospitalName,
       SUM(CASE WHEN b.PaymentStatus = 'Pending' THEN b.TotalAmount ELSE 0 END) AS PendingAmount,
       SUM(b.TotalAmount) AS TotalAmount,
       ROUND(SUM(CASE WHEN b.PaymentStatus = 'Pending' THEN b.TotalAmount ELSE 0 END)
             / SUM(b.TotalAmount) * 100, 1) AS PendingPct
FROM Billing b
JOIN Admissions ad ON b.AdmissionID = ad.AdmissionID
JOIN Hospitals  h  ON ad.HospitalID = h.HospitalID
GROUP BY h.HospitalName
ORDER BY PendingPct DESC;
-- Finding: $1.60M (14.9%) is pending. Hospital 4 has the highest pending share (18.3%),
-- Hospital 1 the lowest (11.5%); most pending bills are from Aug-Sep 2026 discharges.


-- Q10: How much revenue is given away as discount?
--      Measured against gross charges. TotalAmount is already net of
--      discount, so dividing by it would overstate the rate.
WITH BillGross AS (
    SELECT b.AdmissionID, b.Discount,
           COALESCE(b.ConsultationCharge,0) + COALESCE(b.RoomCharge,0) + COALESCE(b.MedicineCharge,0)
         + COALESCE(b.LabCharge,0) + COALESCE(b.SurgeryCharge,0) + COALESCE(b.OtherCharge,0) AS GrossCharges
    FROM Billing b
)
SELECT h.HospitalName,
       SUM(bg.GrossCharges)  AS GrossCharges,
       SUM(bg.Discount)      AS TotalDiscount,
       ROUND(SUM(bg.Discount) / NULLIF(SUM(bg.GrossCharges), 0) * 100, 1) AS DiscountPctOfGross
FROM BillGross bg
JOIN Admissions ad ON bg.AdmissionID = ad.AdmissionID
JOIN Hospitals  h  ON ad.HospitalID  = h.HospitalID
GROUP BY h.HospitalName
ORDER BY DiscountPctOfGross DESC;
-- Finding: Discounts are 0.2-1.2% of gross charges, almost all to self-pay patients.
-- Not a material revenue leak.


-- Q11: Which charge type drives revenue? (Charge Mix visual)
WITH ChargeTotals AS (
              SELECT 'Surgery'      AS ChargeType, SUM(SurgeryCharge)      AS Amount FROM Billing
    UNION ALL SELECT 'Room',                       SUM(RoomCharge)                   FROM Billing
    UNION ALL SELECT 'Medicine',                   SUM(MedicineCharge)               FROM Billing
    UNION ALL SELECT 'Lab',                        SUM(LabCharge)                    FROM Billing
    UNION ALL SELECT 'Consultation',               SUM(ConsultationCharge)           FROM Billing
    UNION ALL SELECT 'Other',                      SUM(OtherCharge)                  FROM Billing
)
SELECT ChargeType, Amount,
       ROUND(Amount / SUM(Amount) OVER () * 100, 1) AS SharePct
FROM ChargeTotals
ORDER BY Amount DESC;
-- Finding: Room (57%) and Surgery (26%) make up 82% of revenue; consultation, lab and medicine
-- together are under 16%.


-- Q12: Which wards earn the most per bed day, at each hospital?
--      Occupancy against physical beds is not used: the dataset is a
--      patient sample, so bed days are far below real hospital capacity.
SELECT h.HospitalName, ad.Ward,
       COUNT(*)                                          AS Admissions,
       SUM(ad.LengthOfStay)                              AS BedDays,
       ROUND(SUM(b.TotalAmount) / SUM(ad.LengthOfStay), 0) AS RevenuePerBedDay
FROM Admissions ad
JOIN Billing   b ON b.AdmissionID = ad.AdmissionID
JOIN Hospitals h ON h.HospitalID  = ad.HospitalID
GROUP BY h.HospitalName, ad.Ward
ORDER BY h.HospitalName, RevenuePerBedDay DESC;
-- Finding: ICU earns ~$5.1-5.3K per bed day vs ~$2.0-2.8K in general wards. Hospital 2 earns the
-- most per bed day in Private, Semi and General wards (orthopedic surgery mix).


-- Q13: Do longer stays produce proportionally higher bills?
SELECT CASE WHEN ad.LengthOfStay <= 3 THEN '1-3 days'
            WHEN ad.LengthOfStay <= 7 THEN '4-7 days'
            ELSE '8+ days' END             AS StayBand,
       COUNT(*)                            AS Admissions,
       ROUND(AVG(b.TotalAmount), 2)        AS AvgBill,
       ROUND(SUM(b.TotalAmount) / SUM(ad.LengthOfStay), 2) AS RevenuePerBedDay
FROM Admissions ad
JOIN Billing b ON ad.AdmissionID = b.AdmissionID
WHERE ad.LengthOfStay IS NOT NULL
GROUP BY StayBand
ORDER BY MIN(ad.LengthOfStay);
-- Finding: Revenue per bed day is flat (~$2.75-2.80K) across stay bands: bills scale with
-- length of stay, so LOS reduction directly reduces revenue per case.


-- Q14: Emergency or regular admissions: which drives more revenue?
SELECT ad.AdmissionType,
       COUNT(*)                     AS Admissions,
       ROUND(AVG(b.TotalAmount), 2) AS AvgBill,
       SUM(b.TotalAmount)           AS TotalRevenue,
       ROUND(SUM(b.TotalAmount) / SUM(SUM(b.TotalAmount)) OVER () * 100, 1) AS RevenueSharePct
FROM Admissions ad
JOIN Billing b ON ad.AdmissionID = b.AdmissionID
GROUP BY ad.AdmissionType;
-- Finding: Emergency and planned admissions bill about the same ($13.2K vs $12.9K average);
-- planned admissions bring 52% of inpatient revenue.


-- =============================================================
-- SECTION 3: DOCTOR STAFFING & WORKLOAD
-- =============================================================

-- Q15: Which doctors carry the most appointments?
SELECT doc.DoctorName, doc.Specialization,
       COUNT(*) AS Appointments,
       RANK() OVER (ORDER BY COUNT(*) DESC) AS WorkloadRank
FROM Appointments a
JOIN Doctors doc ON doc.DoctorID = a.DoctorID
GROUP BY doc.DoctorID, doc.DoctorName, doc.Specialization
ORDER BY Appointments DESC;
-- Finding: Doctor 15 (Orthopedics) leads with 408 appointments, 1.5x the next doctor (266).


-- Q16: Are any doctors close to fully booked?
SELECT doc.DoctorName, doc.Specialization,
       SUM(ds.BookedSlots)    AS BookedSlots,
       SUM(ds.AvailableSlots) AS AvailableSlots,
       ROUND(SUM(ds.BookedSlots) / NULLIF(SUM(ds.AvailableSlots), 0) * 100, 1) AS UtilizationPct
FROM DoctorSchedule ds
JOIN Doctors doc ON ds.DoctorID = doc.DoctorID
GROUP BY doc.DoctorID, doc.DoctorName, doc.Specialization
HAVING SUM(ds.AvailableSlots) > 0          -- ICU / Radiology run no clinics
ORDER BY UtilizationPct DESC;
-- Finding: Clinic slot utilization is 79.1% overall: top doctors run at ~93% (General Medicine),
-- Dermatology at ~61%. Capacity exists, but not where demand is.


-- Q17: Is workload even across departments?
SELECT dep.DepartmentName,
       COUNT(DISTINCT doc.DoctorID) AS Doctors,
       COUNT(a.AppointmentID)       AS Appointments,
       ROUND(COUNT(a.AppointmentID) / COUNT(DISTINCT doc.DoctorID), 1) AS AppointmentsPerDoctor
FROM Departments dep
JOIN Doctors doc ON dep.DepartmentID = doc.DepartmentID
LEFT JOIN Appointments a ON doc.DoctorID = a.DoctorID
GROUP BY dep.DepartmentName
HAVING COUNT(a.AppointmentID) > 0          -- ICU / Radiology run no clinics
ORDER BY AppointmentsPerDoctor DESC;
-- Finding: Orthopedics' 2 doctors handle 251 appointments each, 2x the clinic average of 121;
-- Oncology doctors handle 29 each.


-- Q18: Which departments have the thinnest emergency cover?
--      Normalized per doctor so large departments don't look better by default.
SELECT dep.DepartmentName,
       COUNT(DISTINCT doc.DoctorID) AS Doctors,
       COUNT(ds.ScheduleID)         AS EmergencyShifts,
       ROUND(COUNT(ds.ScheduleID) / NULLIF(COUNT(DISTINCT doc.DoctorID), 0), 1) AS EmergencyShiftsPerDoctor
FROM Departments dep
LEFT JOIN Doctors doc        ON dep.DepartmentID = doc.DepartmentID
LEFT JOIN DoctorSchedule ds  ON doc.DoctorID = ds.DoctorID
                            AND ds.EmergencyDuty = 'Yes'
GROUP BY dep.DepartmentName
ORDER BY EmergencyShiftsPerDoctor ASC;
-- Finding: Outside 24/7 units (ICU, Radiology), Emergency carries the most emergency shifts per
-- doctor (5.8); Surgery has none in the schedule.


-- Q19: Does experience change volume or consultation length?
SELECT CASE WHEN doc.ExperienceYears < 5  THEN '0-4 years'
            WHEN doc.ExperienceYears < 10 THEN '5-9 years'
            WHEN doc.ExperienceYears < 20 THEN '10-19 years'
            ELSE '20+ years' END                     AS ExperienceBand,
       COUNT(DISTINCT doc.DoctorID)                  AS Doctors,
       ROUND(COUNT(a.AppointmentID) / COUNT(DISTINCT doc.DoctorID), 1) AS AppointmentsPerDoctor,
       ROUND(AVG(a.ConsultationMinutes), 1)          AS AvgConsultMin
FROM Doctors doc
LEFT JOIN Appointments a ON doc.DoctorID = a.DoctorID
GROUP BY ExperienceBand
ORDER BY MIN(doc.ExperienceYears);
-- Finding: Experience does not change consultation length (18-20 min in every band) or
-- workload in a consistent way.


-- Q20: Which specializations are under-staffed for their demand?
SELECT doc.Specialization,
       COUNT(DISTINCT doc.DoctorID)          AS Doctors,
       COUNT(a.AppointmentID)                AS Appointments,
       ROUND(COUNT(a.AppointmentID) / COUNT(DISTINCT doc.DoctorID), 1) AS AppointmentsPerDoctor,
       ROUND(AVG(a.WaitingTimeMinutes), 1)   AS AvgWaitMin
FROM Doctors doc
LEFT JOIN Appointments a ON doc.DoctorID = a.DoctorID
GROUP BY doc.Specialization
HAVING COUNT(a.AppointmentID) > 0
ORDER BY AppointmentsPerDoctor DESC;
-- Finding: Orthopedics (251 visits/doctor) and General Medicine (178/doctor, 30-min waits) are
-- the most stretched; adding clinic sessions there would cut the longest planned waits.
