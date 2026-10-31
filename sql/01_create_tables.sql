-- =============================================================
-- Hospital EHR Analytics | 01 Create Tables
-- -------------------------------------------------------------
-- Creates the 11-table hospital data model in MySQL 8.
-- Safe to re-run: every table is dropped and recreated.
--
-- Model overview
--   Reference : Hospitals, Departments, Doctors, Medicines, Patients
--   Facts     : Admissions, Appointments, LabTests, Prescriptions,
--               Billing, DoctorSchedule
--
-- Derived columns that arrive pre-computed in the CSVs are part of
-- the DDL here (no ALTER TABLE patches later):
--   Patients.CalculatedAge, Patients.AgeMismatch
--   Admissions.LengthOfStay
--   LabTests.IsAbnormalResult
-- =============================================================

CREATE DATABASE IF NOT EXISTS hospitalehr_db;
USE hospitalehr_db;

-- Drop children before parents. FK checks are paused only because
-- Departments.HeadDoctorID and Doctors.DepartmentID reference each other.
SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS Billing;
DROP TABLE IF EXISTS Prescriptions;
DROP TABLE IF EXISTS LabTests;
DROP TABLE IF EXISTS Appointments;
DROP TABLE IF EXISTS Admissions;
DROP TABLE IF EXISTS DoctorSchedule;
DROP TABLE IF EXISTS Medicines;
DROP TABLE IF EXISTS Patients;
DROP TABLE IF EXISTS Doctors;
DROP TABLE IF EXISTS Departments;
DROP TABLE IF EXISTS Hospitals;
SET FOREIGN_KEY_CHECKS = 1;


-- -------------------------------------------------------------
-- Hospitals: one row per branch; capacity used for occupancy KPIs
-- -------------------------------------------------------------
CREATE TABLE Hospitals (
    HospitalID          INT          NOT NULL,
    HospitalName        VARCHAR(50)  NOT NULL,
    Branch              VARCHAR(50)  NULL,
    City                VARCHAR(50)  NULL,
    TotalBeds           INT          NULL,
    ICUBeds             INT          NULL,
    EmergencyAvailable  VARCHAR(10)  NULL,
    ContactNumber       VARCHAR(20)  NULL,
    Email               VARCHAR(50)  NULL,
    PRIMARY KEY (HospitalID)
);

-- -------------------------------------------------------------
-- Departments: staffing per department within a hospital.
-- HeadDoctorID FK is added at the end of 02_load_data.sql,
-- after Doctors is loaded (circular reference).
-- -------------------------------------------------------------
CREATE TABLE Departments (
    DepartmentID    INT          NOT NULL,
    DepartmentName  VARCHAR(50)  NOT NULL,
    HospitalID      INT          NULL,
    HeadDoctorID    INT          NULL,
    Floor           INT          NULL,
    TotalDoctors    INT          NULL,
    TotalNurses     INT          NULL,
    PRIMARY KEY (DepartmentID),
    FOREIGN KEY (HospitalID) REFERENCES Hospitals(HospitalID)
);

-- -------------------------------------------------------------
-- Doctors: profile, specialization and assignment
-- -------------------------------------------------------------
CREATE TABLE Doctors (
    DoctorID         INT            NOT NULL,
    DoctorName       VARCHAR(50)    NOT NULL,
    Gender           VARCHAR(20)    NULL,
    Age              INT            NULL,
    Qualification    VARCHAR(50)    NULL,
    Specialization   VARCHAR(50)    NULL,
    ExperienceYears  INT            NULL,
    DepartmentID     INT            NULL,
    HospitalID       INT            NULL,
    Phone            VARCHAR(20)    NULL,
    Email            VARCHAR(50)    NULL,
    Salary           DECIMAL(10,2)  NULL,
    JoiningDate      DATE           NULL,
    PRIMARY KEY (DoctorID),
    FOREIGN KEY (DepartmentID) REFERENCES Departments(DepartmentID),
    FOREIGN KEY (HospitalID)   REFERENCES Hospitals(HospitalID)
);

-- -------------------------------------------------------------
-- DoctorSchedule: one row per doctor shift; slot utilization
-- -------------------------------------------------------------
CREATE TABLE DoctorSchedule (
    ScheduleID      INT          NOT NULL,
    DoctorID        INT          NOT NULL,
    Date            DATE         NULL,
    Shift           VARCHAR(20)  NULL,
    StartTime       TIME         NULL,
    EndTime         TIME         NULL,
    AvailableSlots  INT          NULL,
    BookedSlots     INT          NULL,
    EmergencyDuty   VARCHAR(10)  NULL,
    PRIMARY KEY (ScheduleID),
    FOREIGN KEY (DoctorID) REFERENCES Doctors(DoctorID),
    INDEX ix_schedule_date (Date)
);

-- -------------------------------------------------------------
-- Patients: demographic anchor table
-- AgeMismatch = stated Age differs from age calculated from DOB
-- -------------------------------------------------------------
CREATE TABLE Patients (
    PatientID          INT          NOT NULL,
    PatientName        VARCHAR(50)  NOT NULL,
    Gender             VARCHAR(20)  NULL,
    DOB                DATE         NULL,
    Age                INT          NULL,
    BloodGroup         VARCHAR(20)  NULL,
    Phone              VARCHAR(20)  NULL,
    Email              VARCHAR(50)  NULL,
    City               VARCHAR(20)  NULL,
    Insurance          VARCHAR(50)  NULL,
    InsuranceProvider  VARCHAR(50)  NULL,
    CalculatedAge      INT          NULL,
    AgeMismatch        BOOLEAN      NULL,
    PRIMARY KEY (PatientID)
);

-- -------------------------------------------------------------
-- Medicines: catalog referenced by Prescriptions
-- -------------------------------------------------------------
CREATE TABLE Medicines (
    MedicineID     INT            NOT NULL,
    MedicineName   VARCHAR(50)    NOT NULL,
    Category       VARCHAR(30)    NULL,
    Manufacturer   VARCHAR(50)    NULL,
    UnitPrice      DECIMAL(10,2)  NULL,
    StockQuantity  INT            NULL,
    PRIMARY KEY (MedicineID)
);

-- -------------------------------------------------------------
-- Admissions: inpatient stays. DischargeDate / LengthOfStay are
-- NULL while the patient is still admitted.
-- -------------------------------------------------------------
CREATE TABLE Admissions (
    AdmissionID    INT           NOT NULL,
    PatientID      INT           NOT NULL,
    HospitalID     INT           NULL,
    DepartmentID   INT           NULL,
    DoctorID       INT           NULL,
    AdmissionDate  DATETIME      NULL,
    DischargeDate  DATETIME      NULL,
    Diagnosis      VARCHAR(100)  NULL,
    BedNumber      INT           NULL,
    Ward           VARCHAR(30)   NULL,
    AdmissionType  VARCHAR(20)   NULL,
    Status         VARCHAR(20)   NULL,
    LengthOfStay   INT           NULL,
    PRIMARY KEY (AdmissionID),
    FOREIGN KEY (PatientID)    REFERENCES Patients(PatientID),
    FOREIGN KEY (HospitalID)   REFERENCES Hospitals(HospitalID),
    FOREIGN KEY (DepartmentID) REFERENCES Departments(DepartmentID),
    FOREIGN KEY (DoctorID)     REFERENCES Doctors(DoctorID),
    INDEX ix_admission_date (AdmissionDate)
);

-- -------------------------------------------------------------
-- Appointments: outpatient visits; wait and consultation minutes
-- -------------------------------------------------------------
CREATE TABLE Appointments (
    AppointmentID        INT          NOT NULL,
    PatientID            INT          NOT NULL,
    DoctorID             INT          NOT NULL,
    HospitalID           INT          NULL,
    AppointmentDate      DATETIME     NULL,
    AppointmentTime      TIME         NULL,
    VisitType            VARCHAR(20)  NULL,
    Status               VARCHAR(20)  NULL,
    WaitingTimeMinutes   INT          NULL,
    ConsultationMinutes  INT          NULL,
    PRIMARY KEY (AppointmentID),
    FOREIGN KEY (PatientID)  REFERENCES Patients(PatientID),
    FOREIGN KEY (DoctorID)   REFERENCES Doctors(DoctorID),
    FOREIGN KEY (HospitalID) REFERENCES Hospitals(HospitalID),
    INDEX ix_appointment_date (AppointmentDate)
);

-- -------------------------------------------------------------
-- LabTests: one row per test. Linked to patient, not admission,
-- so lab-to-stay analysis is patient-level only.
-- -------------------------------------------------------------
CREATE TABLE LabTests (
    TestID            INT            NOT NULL,
    PatientID         INT            NOT NULL,
    DoctorID          INT            NOT NULL,
    TestName          VARCHAR(50)    NULL,
    TestDate          DATE           NULL,
    Result            VARCHAR(20)    NULL,
    Cost              DECIMAL(10,2)  NULL,
    IsAbnormalResult  BOOLEAN        NULL,
    PRIMARY KEY (TestID),
    FOREIGN KEY (PatientID) REFERENCES Patients(PatientID),
    FOREIGN KEY (DoctorID)  REFERENCES Doctors(DoctorID)
);

-- -------------------------------------------------------------
-- Prescriptions: medicine orders per patient
-- -------------------------------------------------------------
CREATE TABLE Prescriptions (
    PrescriptionID    INT       NOT NULL,
    PatientID         INT       NOT NULL,
    DoctorID          INT       NOT NULL,
    MedicineID        INT       NOT NULL,
    Quantity          INT       NULL,
    Days              INT       NULL,
    PrescriptionDate  DATETIME  NULL,
    PRIMARY KEY (PrescriptionID),
    FOREIGN KEY (PatientID)  REFERENCES Patients(PatientID),
    FOREIGN KEY (DoctorID)   REFERENCES Doctors(DoctorID),
    FOREIGN KEY (MedicineID) REFERENCES Medicines(MedicineID)
);

-- -------------------------------------------------------------
-- Billing: itemized charges per admission.
-- Expected: TotalAmount = sum of charges - Discount + GST
-- (verified in 03_data_quality_checks.sql)
-- -------------------------------------------------------------
CREATE TABLE Billing (
    BillID              INT            NOT NULL,
    PatientID           INT            NOT NULL,
    AdmissionID         INT            NOT NULL,
    ConsultationCharge  DECIMAL(10,2)  NULL,
    RoomCharge          DECIMAL(10,2)  NULL,
    MedicineCharge      DECIMAL(10,2)  NULL,
    LabCharge           DECIMAL(10,2)  NULL,
    SurgeryCharge       DECIMAL(10,2)  NULL,
    OtherCharge         DECIMAL(10,2)  NULL,
    Discount            DECIMAL(10,2)  NULL,
    GST                 DECIMAL(10,2)  NULL,
    TotalAmount         DECIMAL(10,2)  NULL,
    PaymentMethod       VARCHAR(20)    NULL,
    PaymentStatus       VARCHAR(20)    NULL,
    PRIMARY KEY (BillID),
    FOREIGN KEY (PatientID)   REFERENCES Patients(PatientID),
    FOREIGN KEY (AdmissionID) REFERENCES Admissions(AdmissionID)
);
