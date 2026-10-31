-- =============================================================
-- Hospital EHR Analytics | 03 Data Quality Checks
-- -------------------------------------------------------------
-- Run after 02_load_data.sql and before any analysis.
-- Each check states what a clean result looks like. Record the
-- outcome in the README "Data quality" section.
-- =============================================================

USE hospitalehr_db;


-- -------------------------------------------------------------
-- 1. Coverage: date range of every fact table
--    Clean: all tables cover the same period; no 1900 / 2099 dates
-- -------------------------------------------------------------
SELECT 'Admissions'     AS TableName, MIN(AdmissionDate)    AS FirstDate, MAX(AdmissionDate)    AS LastDate, COUNT(*) AS RowCnt FROM Admissions
UNION ALL SELECT 'Appointments',   MIN(AppointmentDate),  MAX(AppointmentDate),  COUNT(*) FROM Appointments
UNION ALL SELECT 'LabTests',       MIN(TestDate),         MAX(TestDate),         COUNT(*) FROM LabTests
UNION ALL SELECT 'Prescriptions',  MIN(PrescriptionDate), MAX(PrescriptionDate), COUNT(*) FROM Prescriptions
UNION ALL SELECT 'DoctorSchedule', MIN(Date),             MAX(Date),             COUNT(*) FROM DoctorSchedule;


-- -------------------------------------------------------------
-- 2. Monthly volume (explains gaps in the Monthly Activity visual)
--    If a month exists here but is missing in Power BI, the issue
--    is the date-table relationship, not the data.
-- -------------------------------------------------------------
SELECT DATE_FORMAT(AdmissionDate, '%Y-%m') AS YearMonth, COUNT(*) AS Admissions
FROM Admissions
GROUP BY YearMonth
ORDER BY YearMonth;

SELECT DATE_FORMAT(AppointmentDate, '%Y-%m') AS YearMonth, COUNT(*) AS Appointments
FROM Appointments
GROUP BY YearMonth
ORDER BY YearMonth;


-- -------------------------------------------------------------
-- 3. Category values: spelling, casing and stray characters
--    Clean: one spelling per category; LongestValue matches the
--    visible text (a longer value means hidden '\r' or spaces)
-- -------------------------------------------------------------
SELECT 'Admissions.AdmissionType' AS Field, AdmissionType AS Value, COUNT(*) AS RowCnt, MAX(LENGTH(AdmissionType)) AS LongestValue FROM Admissions GROUP BY AdmissionType
UNION ALL SELECT 'Admissions.Ward',         Ward,          COUNT(*), MAX(LENGTH(Ward))          FROM Admissions     GROUP BY Ward
UNION ALL SELECT 'Admissions.Status',       Status,        COUNT(*), MAX(LENGTH(Status))        FROM Admissions     GROUP BY Status
UNION ALL SELECT 'Appointments.VisitType',  VisitType,     COUNT(*), MAX(LENGTH(VisitType))     FROM Appointments   GROUP BY VisitType
UNION ALL SELECT 'Appointments.Status',     Status,        COUNT(*), MAX(LENGTH(Status))        FROM Appointments   GROUP BY Status
UNION ALL SELECT 'LabTests.Result',         Result,        COUNT(*), MAX(LENGTH(Result))        FROM LabTests       GROUP BY Result
UNION ALL SELECT 'Billing.PaymentMethod',   PaymentMethod, COUNT(*), MAX(LENGTH(PaymentMethod)) FROM Billing        GROUP BY PaymentMethod
UNION ALL SELECT 'Billing.PaymentStatus',   PaymentStatus, COUNT(*), MAX(LENGTH(PaymentStatus)) FROM Billing        GROUP BY PaymentStatus
UNION ALL SELECT 'DoctorSchedule.EmergencyDuty', EmergencyDuty, COUNT(*), MAX(LENGTH(EmergencyDuty)) FROM DoctorSchedule GROUP BY EmergencyDuty
ORDER BY Field, Value;


-- -------------------------------------------------------------
-- 4. Admissions logic
--    Clean: every count is 0, except OpenStays (patients still admitted)
-- -------------------------------------------------------------
SELECT
    COUNT(*)                                                         AS Admissions,
    SUM(DischargeDate IS NULL)                                       AS OpenStays,
    SUM(DischargeDate < AdmissionDate)                               AS DischargeBeforeAdmission,
    SUM(LengthOfStay = 0)                                            AS ZeroDayStays,
    SUM(LengthOfStay <> DATEDIFF(DischargeDate, AdmissionDate))      AS LosMismatch,
    SUM(DischargeDate IS NULL AND LengthOfStay IS NOT NULL)          AS LosWithoutDischarge,
    SUM(DischargeDate IS NOT NULL
        AND Status NOT IN ('Discharged', 'Transferred'))             AS DischargedButStatusOpen
FROM Admissions;


-- -------------------------------------------------------------
-- 5. Billing reconciliation
--    Clean: BillsNotReconciling = 0; one bill per admission
-- -------------------------------------------------------------
SELECT
    COUNT(*) AS Bills,
    SUM(ABS(
          COALESCE(ConsultationCharge,0) + COALESCE(RoomCharge,0) + COALESCE(MedicineCharge,0)
        + COALESCE(LabCharge,0) + COALESCE(SurgeryCharge,0) + COALESCE(OtherCharge,0)
        - COALESCE(Discount,0) + COALESCE(GST,0) - TotalAmount) > 1)   AS BillsNotReconciling,
    COUNT(DISTINCT AdmissionID)                                        AS AdmissionsBilled,
    (SELECT COUNT(*) FROM Admissions)                                  AS AdmissionsTotal,
    SUM(TotalAmount < 0)                                               AS NegativeBills
FROM Billing;

-- Bill patient must match admission patient. Clean: 0 rows
-- History: on the original 100-patient sample this returned 79 of 80 rows
-- (repaired by archive/02b_repair_keys.sql). The generated dataset returns 0.
-- Revenue analysis still joins Billing -> Admissions on AdmissionID.
SELECT b.BillID, b.PatientID AS BillPatient, ad.PatientID AS AdmissionPatient
FROM Billing b
JOIN Admissions ad ON ad.AdmissionID = b.AdmissionID
WHERE b.PatientID <> ad.PatientID;


-- -------------------------------------------------------------
-- 6. Appointments and schedule ranges
--    Clean: no negative or extreme minutes; booked <= available
-- -------------------------------------------------------------
SELECT
    MIN(WaitingTimeMinutes)          AS MinWait,
    MAX(WaitingTimeMinutes)          AS MaxWait,
    MIN(ConsultationMinutes)         AS MinConsult,
    MAX(ConsultationMinutes)         AS MaxConsult,
    SUM(WaitingTimeMinutes IS NULL)  AS MissingWait,
    SUM(ConsultationMinutes IS NULL) AS MissingConsult
FROM Appointments;

SELECT COUNT(*) AS Shifts,
       SUM(BookedSlots > AvailableSlots) AS OverbookedShifts,
       SUM(EndTime <= StartTime)         AS ShiftEndsBeforeStart
FROM DoctorSchedule;


-- -------------------------------------------------------------
-- 7. Patients
--    Total vs active patients explains 100 in the table vs
--    97 on the dashboard (3 patients have no encounters).
-- -------------------------------------------------------------
SELECT
    COUNT(*) AS PatientsInTable,
    SUM(PatientID IN (SELECT PatientID FROM Appointments)
     OR PatientID IN (SELECT PatientID FROM Admissions)) AS PatientsWithEncounter,
    SUM(AgeMismatch)                                     AS AgeMismatchRows
FROM Patients;

-- Possible duplicate people. Clean: 0 rows
SELECT PatientName, DOB, COUNT(*) AS Records
FROM Patients
GROUP BY PatientName, DOB
HAVING COUNT(*) > 1;


-- -------------------------------------------------------------
-- 8. Hospitals actually used by each fact table
--    Every hospital in a visual should exist in the slicer list.
-- -------------------------------------------------------------
SELECT h.HospitalID, h.HospitalName,
       (SELECT COUNT(*) FROM Admissions   ad WHERE ad.HospitalID = h.HospitalID) AS Admissions,
       (SELECT COUNT(*) FROM Appointments a  WHERE a.HospitalID  = h.HospitalID) AS Appointments,
       (SELECT COUNT(*) FROM Departments  d  WHERE d.HospitalID  = h.HospitalID) AS Departments
FROM Hospitals h
ORDER BY h.HospitalID;


-- -------------------------------------------------------------
-- 9. Cross-table consistency
--    The same fact stored in two tables must agree.
--    Clean: every Mismatches value is 0
-- -------------------------------------------------------------
SELECT 'Appointment hospital vs doctor hospital' AS CheckName, COUNT(*) AS Mismatches
FROM Appointments a
JOIN Doctors doc ON doc.DoctorID = a.DoctorID
WHERE a.HospitalID <> doc.HospitalID
UNION ALL
SELECT 'Admission hospital vs department hospital', COUNT(*)
FROM Admissions ad
JOIN Departments dep ON dep.DepartmentID = ad.DepartmentID
WHERE ad.HospitalID <> dep.HospitalID
UNION ALL
SELECT 'Admission department vs doctor department', COUNT(*)
FROM Admissions ad
JOIN Doctors doc ON doc.DoctorID = ad.DoctorID
WHERE ad.DepartmentID <> doc.DepartmentID
UNION ALL
SELECT 'Doctor hospital vs department hospital', COUNT(*)
FROM Doctors doc
JOIN Departments dep ON dep.DepartmentID = doc.DepartmentID
WHERE doc.HospitalID <> dep.HospitalID;
