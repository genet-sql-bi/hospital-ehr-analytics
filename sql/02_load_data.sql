-- =============================================================
-- Hospital EHR Analytics | 02 Load Data
-- -------------------------------------------------------------
-- Bulk-loads the 11 CSVs in the data/ folder
-- into the tables created by 01_create_tables.sql.
-- Tables load parents-first so every foreign key is enforced.
--
-- Before running
--   1. Run 01_create_tables.sql (gives empty tables).
--   2. Enable local file loading:
--        SET GLOBAL local_infile = 1;
--      and in the Workbench connection: Advanced > Others >
--        OPT_LOCAL_INFILE=1
--   3. Find-and-replace the folder path below with your own.
--      MySQL does not accept a variable as a LOAD DATA file name.
--
-- Robustness choices
--   * The last column of every file is read into a variable and the
--     trailing '\r' is stripped, so files saved with Windows (CRLF)
--     or Unix (LF) line endings both load cleanly. Without this,
--     values like 'Pending\r' silently fail WHERE PaymentStatus = 'Pending'.
--   * Blank DischargeDate / LengthOfStay become NULL (still admitted),
--     not 0 or 0000-00-00, which would distort length-of-stay averages.
-- =============================================================

USE hospitalehr_db;

-- Hospitals ---------------------------------------------------
LOAD DATA LOCAL INFILE 'C:/GitProjects/hospital-ehr-analytics/data/Hospital_Cleaned.csv'
INTO TABLE Hospitals
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(HospitalID, HospitalName, Branch, City, TotalBeds, ICUBeds, EmergencyAvailable, ContactNumber, @Email)
SET Email = NULLIF(TRIM(TRAILING '\r' FROM @Email), '');

-- Departments (HeadDoctorID FK added at the end) --------------
LOAD DATA LOCAL INFILE 'C:/GitProjects/hospital-ehr-analytics/data/Department_Cleaned.csv'
INTO TABLE Departments
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(DepartmentID, DepartmentName, HospitalID, HeadDoctorID, Floor, TotalDoctors, @TotalNurses)
SET TotalNurses = NULLIF(TRIM(TRAILING '\r' FROM @TotalNurses), '');

-- Doctors -----------------------------------------------------
LOAD DATA LOCAL INFILE 'C:/GitProjects/hospital-ehr-analytics/data/Doctors_Cleaned.csv'
INTO TABLE Doctors
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(DoctorID, DoctorName, Gender, Age, Qualification, Specialization, ExperienceYears,
 DepartmentID, HospitalID, Phone, Email, Salary, @JoiningDate)
SET JoiningDate = NULLIF(TRIM(TRAILING '\r' FROM @JoiningDate), '');

-- DoctorSchedule ----------------------------------------------
LOAD DATA LOCAL INFILE 'C:/GitProjects/hospital-ehr-analytics/data/Doctor_Schedule_Cleaned.csv'
INTO TABLE DoctorSchedule
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(ScheduleID, DoctorID, Date, Shift, StartTime, EndTime, AvailableSlots, BookedSlots, @EmergencyDuty)
SET EmergencyDuty = NULLIF(TRIM(TRAILING '\r' FROM @EmergencyDuty), '');

-- Patients ----------------------------------------------------
LOAD DATA LOCAL INFILE 'C:/GitProjects/hospital-ehr-analytics/data/Patients_Cleaned.csv'
INTO TABLE Patients
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(PatientID, PatientName, Gender, DOB, Age, BloodGroup, Phone, Email, City,
 Insurance, InsuranceProvider, CalculatedAge, @AgeMismatch)
SET AgeMismatch = (UPPER(TRIM(TRAILING '\r' FROM @AgeMismatch)) = 'TRUE');

-- Medicines ---------------------------------------------------
LOAD DATA LOCAL INFILE 'C:/GitProjects/hospital-ehr-analytics/data/Medicines_Cleaned.csv'
INTO TABLE Medicines
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(MedicineID, MedicineName, Category, Manufacturer, UnitPrice, @StockQuantity)
SET StockQuantity = NULLIF(TRIM(TRAILING '\r' FROM @StockQuantity), '');

-- Admissions --------------------------------------------------
LOAD DATA LOCAL INFILE 'C:/GitProjects/hospital-ehr-analytics/data/Admissions_Cleaned.csv'
INTO TABLE Admissions
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(AdmissionID, PatientID, HospitalID, DepartmentID, DoctorID, AdmissionDate, @DischargeDate,
 Diagnosis, BedNumber, Ward, AdmissionType, Status, @LengthOfStay)
SET DischargeDate = NULLIF(@DischargeDate, ''),
    LengthOfStay  = NULLIF(TRIM(TRAILING '\r' FROM @LengthOfStay), '');

-- Appointments ------------------------------------------------
LOAD DATA LOCAL INFILE 'C:/GitProjects/hospital-ehr-analytics/data/Appointments_Cleaned.csv'
INTO TABLE Appointments
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(AppointmentID, PatientID, DoctorID, HospitalID, AppointmentDate, AppointmentTime,
 VisitType, Status, @WaitingTimeMinutes, @ConsultationMinutes)
SET WaitingTimeMinutes  = NULLIF(@WaitingTimeMinutes, ''),          -- blank for No-Show / Cancelled
    ConsultationMinutes = NULLIF(TRIM(TRAILING '\r' FROM @ConsultationMinutes), '');

-- LabTests ----------------------------------------------------
LOAD DATA LOCAL INFILE 'C:/GitProjects/hospital-ehr-analytics/data/LabTests_Cleaned.csv'
INTO TABLE LabTests
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(TestID, PatientID, DoctorID, TestName, TestDate, Result, Cost, @IsAbnormalResult)
SET IsAbnormalResult = (UPPER(TRIM(TRAILING '\r' FROM @IsAbnormalResult)) = 'TRUE');

-- Prescriptions -----------------------------------------------
LOAD DATA LOCAL INFILE 'C:/GitProjects/hospital-ehr-analytics/data/Prescriptions_Cleaned.csv'
INTO TABLE Prescriptions
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(PrescriptionID, PatientID, DoctorID, MedicineID, Quantity, Days, @PrescriptionDate)
SET PrescriptionDate = NULLIF(TRIM(TRAILING '\r' FROM @PrescriptionDate), '');

-- Billing -----------------------------------------------------
LOAD DATA LOCAL INFILE 'C:/GitProjects/hospital-ehr-analytics/data/Bills_Cleaned.csv'
INTO TABLE Billing
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(BillID, PatientID, AdmissionID, ConsultationCharge, RoomCharge, MedicineCharge, LabCharge,
 SurgeryCharge, OtherCharge, Discount, GST, TotalAmount, PaymentMethod, @PaymentStatus)
SET PaymentStatus = NULLIF(TRIM(TRAILING '\r' FROM @PaymentStatus), '');


-- =============================================================
-- Close the Departments <-> Doctors loop
-- The check must return 0 rows before the constraint can be added.
-- =============================================================
SELECT dep.DepartmentID, dep.HeadDoctorID
FROM Departments dep
LEFT JOIN Doctors doc ON doc.DoctorID = dep.HeadDoctorID
WHERE dep.HeadDoctorID IS NOT NULL
  AND doc.DoctorID IS NULL;

ALTER TABLE Departments
    ADD CONSTRAINT fk_departments_head_doctor
    FOREIGN KEY (HeadDoctorID) REFERENCES Doctors(DoctorID);


-- =============================================================
-- Verify: row counts should match the CSV row counts
-- =============================================================
SELECT 'Hospitals'      AS TableName, COUNT(*) AS RowCnt FROM Hospitals
UNION ALL SELECT 'Departments',    COUNT(*) FROM Departments
UNION ALL SELECT 'Doctors',        COUNT(*) FROM Doctors
UNION ALL SELECT 'DoctorSchedule', COUNT(*) FROM DoctorSchedule
UNION ALL SELECT 'Patients',       COUNT(*) FROM Patients
UNION ALL SELECT 'Medicines',      COUNT(*) FROM Medicines
UNION ALL SELECT 'Admissions',     COUNT(*) FROM Admissions
UNION ALL SELECT 'Appointments',   COUNT(*) FROM Appointments
UNION ALL SELECT 'LabTests',       COUNT(*) FROM LabTests
UNION ALL SELECT 'Prescriptions',  COUNT(*) FROM Prescriptions
UNION ALL SELECT 'Billing',        COUNT(*) FROM Billing;
