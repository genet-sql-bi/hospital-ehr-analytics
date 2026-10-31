-- =============================================================
-- Hospital EHR Analytics | 02b Repair Inconsistent Keys
-- -------------------------------------------------------------
-- Run after 02_load_data.sql, then re-run check 9 and the billing
-- check in 03_data_quality_checks.sql (all mismatches should be 0).
--
-- Why
--   The source data stores hospital and department in several tables,
--   and they disagree (found by 03 check 9 and the billing check):
--     Appointment hospital  vs doctor's hospital    : 165 of 200
--     Admission hospital    vs department's hospital:  60 of 80
--     Admission department  vs doctor's department  :  75 of 80
--     Doctor hospital       vs department's hospital:  15
--     Bill patient          vs admission's patient  :  79 of 80
--   With keys this inconsistent, any "by hospital" or "by department"
--   result depends on which join path is used.
--
-- Rule: one source of truth, following the org hierarchy
--   Department -> Hospital       (Departments.HospitalID is trusted)
--   Doctor     -> Department     (Doctors.DepartmentID is trusted)
--   Encounter  -> Doctor         (the treating doctor sets department and hospital)
--   Bill       -> Admission      (the admission sets the patient)
--
-- The CSVs are untouched; re-running 01 + 02 restores the raw data.
-- =============================================================

USE hospitalehr_db;

SET SQL_SAFE_UPDATES = 0;   -- Workbench blocks multi-table UPDATEs otherwise
START TRANSACTION;

-- 1. Doctor's hospital = their department's hospital
UPDATE Doctors doc
JOIN Departments dep ON dep.DepartmentID = doc.DepartmentID
SET doc.HospitalID = dep.HospitalID
WHERE doc.HospitalID <> dep.HospitalID;

-- 2. Appointment's hospital = treating doctor's hospital
UPDATE Appointments a
JOIN Doctors doc ON doc.DoctorID = a.DoctorID
SET a.HospitalID = doc.HospitalID
WHERE a.HospitalID <> doc.HospitalID;

-- 3. Admission's department and hospital = attending doctor's
UPDATE Admissions ad
JOIN Doctors doc ON doc.DoctorID = ad.DoctorID
SET ad.DepartmentID = doc.DepartmentID,
    ad.HospitalID   = doc.HospitalID
WHERE ad.DepartmentID <> doc.DepartmentID
   OR ad.HospitalID   <> doc.HospitalID;

-- 4. Bill's patient = admission's patient
UPDATE Billing b
JOIN Admissions ad ON ad.AdmissionID = b.AdmissionID
SET b.PatientID = ad.PatientID
WHERE b.PatientID <> ad.PatientID;

COMMIT;
SET SQL_SAFE_UPDATES = 1;


-- Verify: every row should show 0
SELECT 'Appointment hospital vs doctor hospital' AS CheckName, COUNT(*) AS Mismatches
FROM Appointments a JOIN Doctors doc ON doc.DoctorID = a.DoctorID
WHERE a.HospitalID <> doc.HospitalID
UNION ALL
SELECT 'Admission hospital vs department hospital', COUNT(*)
FROM Admissions ad JOIN Departments dep ON dep.DepartmentID = ad.DepartmentID
WHERE ad.HospitalID <> dep.HospitalID
UNION ALL
SELECT 'Admission department vs doctor department', COUNT(*)
FROM Admissions ad JOIN Doctors doc ON doc.DoctorID = ad.DoctorID
WHERE ad.DepartmentID <> doc.DepartmentID
UNION ALL
SELECT 'Doctor hospital vs department hospital', COUNT(*)
FROM Doctors doc JOIN Departments dep ON dep.DepartmentID = doc.DepartmentID
WHERE doc.HospitalID <> dep.HospitalID
UNION ALL
SELECT 'Bill patient vs admission patient', COUNT(*)
FROM Billing b JOIN Admissions ad ON ad.AdmissionID = b.AdmissionID
WHERE b.PatientID <> ad.PatientID;
