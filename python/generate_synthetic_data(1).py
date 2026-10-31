"""
Hospital EHR Analytics | Synthetic data generator
=================================================
Generates the 11 cleaned CSVs used by sql/02_load_data.sql, in the same
columns, order and formats as the original 100-patient sample.

Why a generator
  The original sample (100 patients, 6 months) had uneven table coverage and
  inconsistent keys across tables (e.g. 165 of 200 appointments recorded a
  different hospital than their doctor). This generator scales the data to
  1,000 patients over 12 months with referential integrity built in:
    Department -> Hospital, Doctor -> Department,
    Appointment / Admission -> Doctor, Bill -> Admission.

Realism, not real data
  Every value is synthetic. Distributions are set from public norms
  (length of stay by diagnosis, US payer mix, outpatient no-show rates,
  seasonal respiratory peaks). All parameters are in the CONFIG section,
  so any pattern in the dashboard can be traced to an assumption here.

Run:  python generate_synthetic_data.py  [output_folder]
"""

import math
import sys
from datetime import date, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

# =============================================================================
# CONFIG
# =============================================================================
SEED = 42
START = date(2025, 10, 1)          # first encounter date
END = date(2026, 9, 30)            # last admission / appointment date
EXTRACT = date(2026, 10, 15)       # data extract date (payment status as of)
N_PATIENTS = 1_000
TARGET_APPOINTMENTS = 4_800
TARGET_REGULAR_ADMISSIONS = 450
TARGET_EMERGENCY_ADMISSIONS = 330

HOSPITALS = [  # id, name, branch, city, beds, icu_beds, area code, price factor
    (1, "Citycare Hospital 1", "Branch 1", "New York", 261, 23, "212", 1.15),
    (2, "Citycare Hospital 2", "Branch 2", "Los Angeles", 205, 25, "213", 1.10),
    (3, "Citycare Hospital 3", "Branch 3", "Chicago", 208, 21, "312", 1.00),
    (4, "Citycare Hospital 4", "Branch 4", "Phoenix", 296, 33, "602", 0.90),
    (5, "Citycare Hospital 5", "Branch 5", "San Diego", 168, 40, "619", 1.05),
]
CITY_WEIGHTS = [0.24, 0.19, 0.19, 0.24, 0.14]

DEPARTMENTS_BY_HOSPITAL = {
    1: ["Emergency", "General Medicine", "Cardiology", "Oncology", "ICU"],
    2: ["Emergency", "General Medicine", "Orthopedics", "Neurology", "ICU"],
    3: ["Emergency", "General Medicine", "Pediatrics", "Surgery"],
    4: ["Emergency", "General Medicine", "Cardiology", "Dermatology", "Radiology"],
    5: ["Emergency", "General Medicine", "Pediatrics", "ENT", "ICU"],
}
DOCTORS_PER_DEPARTMENT = 2
NON_CLINIC_DEPARTMENTS = {"ICU", "Radiology"}      # no outpatient appointments

# Clinic slot utilization target by department (booked / available)
UTILIZATION_TARGET = {
    "Emergency": 0.92, "General Medicine": 0.88, "Cardiology": 0.86,
    "Orthopedics": 0.84, "Pediatrics": 0.80, "Oncology": 0.78,
    "Neurology": 0.74, "Surgery": 0.70, "ENT": 0.66, "Dermatology": 0.60,
}
SLOTS_PER_SESSION = {"Emergency": 16}              # others: 12
DEFAULT_SLOTS = 12

SALARY_BASE = {  # USD, approximate US specialty medians
    "Emergency": 330_000, "General Medicine": 250_000, "Cardiology": 450_000,
    "Oncology": 420_000, "ICU": 380_000, "Orthopedics": 500_000,
    "Neurology": 380_000, "Pediatrics": 240_000, "Surgery": 450_000,
    "Dermatology": 400_000, "Radiology": 450_000, "ENT": 400_000,
}

# Monthly demand index (respiratory season peaks in winter)
MONTH_WEIGHT = {10: 1.00, 11: 1.05, 12: 1.15, 1: 1.20, 2: 1.10, 3: 1.00,
                4: 0.95, 5: 0.90, 6: 0.85, 7: 0.80, 8: 0.85, 9: 0.95}

# Mean length of stay (days) by diagnosis
LOS_MEAN = {"Asthma": 3.0, "Fever": 2.5, "Covid": 6.0, "Hypertension": 3.0,
            "Diabetes": 4.0, "Migraine": 2.0, "Fracture": 5.0, "Cancer": 8.0}
ICU_LOS_MEAN = 10.0

WARD_DAILY_RATE = {"General": 900, "Semi": 1_400, "Private": 2_200, "ICU": 4_500}

LAB_TESTS = {  # name: (cost low, cost high, base abnormal probability)
    "CBC": (25, 60, 0.22), "Blood Sugar": (10, 30, 0.25),
    "CT": (300, 900, 0.30), "MRI": (700, 2_000, 0.28),
}
PRIVATE_INSURERS = ["Aetna", "Blue Cross", "UnitedHealthcare", "Cigna"]

# =============================================================================
rng = np.random.default_rng(SEED)
DAYS = (END - START).days + 1
ALL_DATES = [START + timedelta(d) for d in range(DAYS)]
DATE_P = np.array([MONTH_WEIGHT[d.month] for d in ALL_DATES], dtype=float)
DATE_P /= DATE_P.sum()


def dt(d):
    """Datetime text in the same format as the original CSVs."""
    return f"{d.isoformat()} 00:00:00"


def pick(options, p=None):
    return options[rng.choice(len(options), p=p)]


def seasonal_date():
    return ALL_DATES[rng.choice(DAYS, p=DATE_P)]


def clip(x, lo, hi):
    return max(lo, min(hi, x))


# =============================================================================
# 1. Hospitals
# =============================================================================
hospitals = pd.DataFrame([{
    "HospitalID": h[0], "HospitalName": h[1], "Branch": h[2], "City": h[3],
    "TotalBeds": h[4], "ICUBeds": h[5], "EmergencyAvailable": "Yes",
    "ContactNumber": f"{h[6]}-555-01{h[0]:02d}",
    "Email": f"branch{h[0]}@citycare.com",
} for h in HOSPITALS])
H = {h[0]: {"city": h[3], "beds": h[4], "area": h[6], "price": h[7]} for h in HOSPITALS}
CITY_TO_HOSPITAL = {h[3]: h[0] for h in HOSPITALS}

# =============================================================================
# 2. Departments and 3. Doctors
# =============================================================================
dept_rows, doctor_rows = [], []
dept_id, doc_id = 0, 0
for hid, names in DEPARTMENTS_BY_HOSPITAL.items():
    for name in names:
        dept_id += 1
        members = []
        for _ in range(DOCTORS_PER_DEPARTMENT):
            doc_id += 1
            age = int(rng.integers(30, 63))
            exp = max(1, age - 29 - int(rng.integers(0, 6)))
            joined_years_ago = int(rng.integers(0, min(exp, 20) + 1))
            joining = date(2026, 1, 1) - timedelta(days=365 * joined_years_ago
                                                   + int(rng.integers(0, 365)))
            salary = SALARY_BASE[name] * rng.uniform(0.85, 1.10) * (1 + 0.008 * exp)
            doctor_rows.append({
                "DoctorID": doc_id, "DoctorName": f"Doctor {doc_id}",
                "Gender": pick(["Female", "Male"]), "Age": age,
                "Qualification": pick(["MD", "DO"], [0.8, 0.2]),
                "Specialization": name, "ExperienceYears": exp,
                "DepartmentID": dept_id, "HospitalID": hid,
                "Phone": f"{H[hid]['area']}-555-{1000 + doc_id}",
                "Email": f"dr{doc_id}@citycare.com",
                "Salary": int(round(salary, -2)), "JoiningDate": dt(joining),
            })
            members.append((doc_id, exp))
        head = max(members, key=lambda m: m[1])[0]
        dept_rows.append({
            "DepartmentID": dept_id, "DepartmentName": name, "HospitalID": hid,
            "HeadDoctorID": head, "Floor": int(rng.integers(1, 7)),
            "TotalDoctors": DOCTORS_PER_DEPARTMENT,
            "TotalNurses": int(rng.integers(18, 36) if name in ("Emergency", "ICU")
                               else rng.integers(6, 20)),
        })
departments = pd.DataFrame(dept_rows)
doctors = pd.DataFrame(doctor_rows)

DEPT_AT = {}            # (hospital, dept name) -> DepartmentID
for r in dept_rows:
    DEPT_AT[(r["HospitalID"], r["DepartmentName"])] = r["DepartmentID"]
DEPT_NAME = {r["DepartmentID"]: r["DepartmentName"] for r in dept_rows}
DEPT_HOSP = {r["DepartmentID"]: r["HospitalID"] for r in dept_rows}
DOCS_IN = {d: doctors.loc[doctors.DepartmentID == d, "DoctorID"].tolist()
           for d in departments.DepartmentID}
DOC_DEPT = dict(zip(doctors.DoctorID, doctors.DepartmentID))
HOSPITALS_WITH = {}
for (hid, name), _ in DEPT_AT.items():
    HOSPITALS_WITH.setdefault(name, []).append(hid)
# Some doctors are in higher demand than their colleagues
DOC_POPULARITY = {d: rng.lognormal(0, 0.35) for d in doctors.DoctorID}

# =============================================================================
# 4. Patients
# =============================================================================
patient_rows, P = [], {}
for pid in range(1, N_PATIENTS + 1):
    band = rng.choice(4, p=[0.18, 0.25, 0.32, 0.25])
    age = int([rng.integers(0, 16), rng.integers(16, 40),
               rng.integers(40, 65), rng.integers(65, 91)][band])
    dob = END - timedelta(days=365 * age + int(rng.integers(0, 365)))
    age = END.year - dob.year - ((END.month, END.day) < (dob.month, dob.day))
    city = pick([h[3] for h in HOSPITALS], CITY_WEIGHTS)
    if age >= 65:
        provider = pick(["Medicare", "Self-Pay"], [0.94, 0.06])
    elif age < 16:
        provider = pick(["Medicaid"] + PRIVATE_INSURERS + ["Self-Pay"],
                        [0.40, 0.14, 0.14, 0.14, 0.13, 0.05])
    else:
        provider = pick(["Medicaid"] + PRIVATE_INSURERS + ["Self-Pay"],
                        [0.12, 0.19, 0.19, 0.19, 0.18, 0.13])
    adult, senior = age >= 18, age >= 65
    chronic = {
        "diabetes": rng.random() < (0.25 if senior else 0.10 if adult else 0.01),
        "hypertension": rng.random() < (0.40 if senior else 0.15 if adult else 0.0),
        "asthma": rng.random() < (0.12 if age < 16 else 0.06),
        "cancer": rng.random() < (0.05 if senior else 0.02 if adult else 0.003),
    }
    P[pid] = {"age": age, "home": CITY_TO_HOSPITAL[city], "provider": provider,
              "chronic": chronic, "senior": senior, "child": age < 16}
    patient_rows.append({
        "PatientID": pid, "PatientName": f"Patient {pid}",
        "Gender": pick(["Female", "Male"], [0.52, 0.48]), "DOB": dt(dob), "Age": age,
        "BloodGroup": pick(["O+", "A+", "B+", "AB+", "O-", "A-", "B-", "AB-"],
                           [0.37, 0.33, 0.09, 0.03, 0.07, 0.06, 0.02, 0.03]),
        "Phone": f"{H[CITY_TO_HOSPITAL[city]]['area']}-555-{2000 + pid:04d}",
        "Email": f"patient{pid}@mail.com", "City": city,
        "Insurance": "No" if provider == "Self-Pay" else "Yes",
        "InsuranceProvider": provider, "CalculatedAge": age, "AgeMismatch": "FALSE",
    })
patients = pd.DataFrame(patient_rows)

# =============================================================================
# 5. Appointments (desired visits first, then fitted into clinic sessions)
# =============================================================================
CLINIC_DEPTS = [d for d in UTILIZATION_TARGET]


def visit_weights(p):
    c = p["chronic"]
    if p["child"]:
        w = {"Pediatrics": 5, "General Medicine": 0.5, "Emergency": 1.6,
             "ENT": 0.8, "Dermatology": 0.5, "Orthopedics": 0.3}
        if c["asthma"]:
            w["Pediatrics"] += 1.5
    else:
        w = {"General Medicine": 3, "Emergency": 1.8, "Dermatology": 0.6, "ENT": 0.6,
             "Orthopedics": 0.8, "Neurology": 0.5, "Cardiology": 0.5,
             "Oncology": 0.1, "Surgery": 0.3}
        if c["diabetes"]:
            w["General Medicine"] += 2
        if c["hypertension"]:
            w["Cardiology"] += 2.5
        if c["asthma"]:
            w["General Medicine"] += 1
        if c["cancer"]:
            w["Oncology"] += 4
            w["Surgery"] += 0.5
        if p["senior"]:
            w["Cardiology"] += 1
            w["Orthopedics"] += 0.5
    return w


def choose_department(p, dept_name):
    """Home hospital if it has the department, otherwise travel or fall back."""
    home = p["home"]
    if (home, dept_name) in DEPT_AT and rng.random() < 0.92:
        return DEPT_AT[(home, dept_name)]
    options = HOSPITALS_WITH[dept_name]
    if (home, dept_name) not in DEPT_AT and dept_name in ("Pediatrics", "Neurology") \
            and rng.random() < 0.5:
        return DEPT_AT[(home, "General Medicine")]
    return DEPT_AT[(pick(options), dept_name)]


lam = np.array([2.5 + 1.5 * sum(P[i]["chronic"].values()) + (1 if P[i]["senior"] else 0)
                for i in P])
lam *= TARGET_APPOINTMENTS / lam.sum()
desired = []          # dicts with patient, doctor, desired date
for pid, l in zip(P, lam):
    p = P[pid]
    w = visit_weights(p)
    names, wts = list(w), np.array(list(w.values()), dtype=float)
    primary = pick(names, wts / wts.sum())
    for _ in range(rng.poisson(l)):
        name = primary if rng.random() < 0.7 else pick(names, wts / wts.sum())
        did = choose_department(p, name)
        docs = DOCS_IN[did]
        pw = np.array([DOC_POPULARITY[d] for d in docs])
        doc = pick(docs, pw / pw.sum())
        desired.append({"PatientID": pid, "DoctorID": doc, "Desired": seasonal_date()})

desired.sort(key=lambda r: r["Desired"])
seen_pair = set()
for r in desired:
    key = (r["PatientID"], DOC_DEPT[r["DoctorID"]])
    r["VisitType"] = "Follow-Up" if key in seen_pair else "New"
    seen_pair.add(key)
    u = rng.random()
    noshow = 0.09 if r["VisitType"] == "Follow-Up" else 0.06
    r["Status"] = "Cancelled" if u < 0.04 else "No-Show" if u < 0.04 + noshow else "Completed"

SHIFT_TIMES = {"Morning": ("09:00", 9 * 60), "Evening": ("14:00", 14 * 60),
               "Night": ("19:00", 19 * 60)}
SESSION_MINUTES = 240


def hhmm(minutes):
    return f"{minutes // 60:02d}:{minutes % 60:02d}"


sessions, appointments = [], []
by_doc = {}
for r in desired:
    by_doc.setdefault(r["DoctorID"], []).append(r)

for doc, rows in by_doc.items():
    dname = DEPT_NAME[DOC_DEPT[doc]]
    slots = SLOTS_PER_SESSION.get(dname, DEFAULT_SLOTS)
    u_doc = clip(UTILIZATION_TARGET[dname] + rng.normal(0, 0.05), 0.45, 0.98)
    booked_rows = [r for r in rows if r["Status"] != "Cancelled"]
    n_sessions = max(1, math.ceil(len(booked_rows) / (slots * u_doc)))
    # Session dates follow demand: placed at quantiles of desired dates
    ords = np.array([r["Desired"].toordinal() for r in booked_rows])
    qs = np.quantile(ords, (np.arange(n_sessions) + 0.5) / n_sessions)
    used, sess_dates = set(), []
    for q in qs:
        d = date.fromordinal(int(round(q)))
        while d in used or (dname != "Emergency" and d.weekday() >= 5) or d > END:
            d = d + timedelta(1) if d < END else d - timedelta(1)
        used.add(d)
        sess_dates.append(d)
    sess_dates.sort()
    # Booked count per session: noisy around the doctor's utilization, capped at slots
    fill = np.clip(rng.normal(u_doc, 0.10, n_sessions), 0.3, 1.0)
    counts = np.floor(fill / fill.sum() * len(booked_rows)).astype(int)
    counts = np.minimum(counts, slots)
    i = 0
    while counts.sum() < len(booked_rows):
        if counts[i % n_sessions] < slots:
            counts[i % n_sessions] += 1
        i += 1
    preferred = "Morning" if rng.random() < 0.7 else "Evening"
    pos = 0
    for k, d in enumerate(sess_dates):
        shift = ["Morning", "Evening", "Night"][k % 3] if dname == "Emergency" else preferred
        start_txt, start_min = SHIFT_TIMES[shift]
        session_rows = booked_rows[pos:pos + counts[k]]
        pos += counts[k]
        sessions.append({"DoctorID": doc, "Date": d, "Shift": shift,
                         "StartTime": start_txt, "EndTime": hhmm(start_min + SESSION_MINUTES),
                         "AvailableSlots": slots, "BookedSlots": len(session_rows),
                         "EmergencyDuty": "Yes" if dname == "Emergency"
                         else ("Yes" if rng.random() < 0.10 else "No")})
        slot_len = SESSION_MINUTES // slots
        slot_ids = sorted(rng.choice(slots, size=len(session_rows), replace=False))
        busy = len(session_rows) / slots
        for r, s in zip(session_rows, slot_ids):
            r.update({"Date": d, "Time": hhmm(start_min + int(s) * slot_len)})
            if r["Status"] == "Completed":
                base = 28 if dname == "Emergency" else 14 if dname == "General Medicine" else 10
                wait = (base + 60 * max(0.0, busy - 0.75) + 0.8 * int(s)
                        + (4 if r["VisitType"] == "New" else 0)) * rng.lognormal(0, 0.35)
                consult = (rng.normal(24, 5) if r["VisitType"] == "New" else rng.normal(13, 4))
                consult += {"Oncology": 4, "Neurology": 4, "Dermatology": -3,
                            "Emergency": 3}.get(dname, 0)
                r["Wait"], r["Consult"] = int(clip(round(wait), 3, 120)), int(clip(round(consult), 5, 60))
    # Cancelled visits go to the session nearest their desired date
    for r in rows:
        if r["Status"] == "Cancelled":
            d = min(sess_dates, key=lambda x: abs((x - r["Desired"]).days))
            sess = next(s for s in sessions if s["DoctorID"] == doc and s["Date"] == d)
            r.update({"Date": d, "Time": sess["StartTime"]})
    appointments.extend(rows)

# Inpatient / diagnostic doctors: duty shifts with no clinic slots
for doc in doctors.DoctorID:
    dname = DEPT_NAME[DOC_DEPT[doc]]
    if dname not in NON_CLINIC_DEPARTMENTS:
        continue
    for d in ALL_DATES:
        if rng.random() < 2 / 7:
            shift = pick(["Morning", "Evening", "Night"])
            st, sm = SHIFT_TIMES[shift]
            sessions.append({"DoctorID": doc, "Date": d, "Shift": shift, "StartTime": st,
                             "EndTime": hhmm(sm + SESSION_MINUTES), "AvailableSlots": 0,
                             "BookedSlots": 0,
                             "EmergencyDuty": "Yes" if rng.random() < (0.5 if dname == "ICU" else 0.2) else "No"})

sessions.sort(key=lambda s: (s["Date"], s["StartTime"], s["DoctorID"]))
schedule = pd.DataFrame([{"ScheduleID": i + 1, "DoctorID": s["DoctorID"], "Date": dt(s["Date"]),
                          "Shift": s["Shift"], "StartTime": s["StartTime"], "EndTime": s["EndTime"],
                          "AvailableSlots": s["AvailableSlots"], "BookedSlots": s["BookedSlots"],
                          "EmergencyDuty": s["EmergencyDuty"]} for i, s in enumerate(sessions)])

appointments.sort(key=lambda r: (r["Date"], r["Time"], r["DoctorID"]))
for i, r in enumerate(appointments):
    r["AppointmentID"] = i + 1
appointments_df = pd.DataFrame([{
    "AppointmentID": r["AppointmentID"], "PatientID": r["PatientID"], "DoctorID": r["DoctorID"],
    "HospitalID": DEPT_HOSP[DOC_DEPT[r["DoctorID"]]], "AppointmentDate": dt(r["Date"]),
    "AppointmentTime": r["Time"], "VisitType": r["VisitType"], "Status": r["Status"],
    "WaitingTimeMinutes": r.get("Wait", ""), "ConsultationMinutes": r.get("Consult", ""),
} for r in appointments])

# =============================================================================
# 6. Admissions
# =============================================================================
ADMIT_FROM_CLINIC = {"Oncology": 0.25, "Surgery": 0.30, "Orthopedics": 0.12,
                     "Cardiology": 0.08, "Neurology": 0.06, "General Medicine": 0.05,
                     "Pediatrics": 0.04}
DIAG_DEPT = {"Hypertension": "Cardiology", "Cancer": "Oncology", "Fracture": "Orthopedics",
             "Migraine": "Neurology", "Diabetes": "General Medicine"}
RESPIRATORY = ["Asthma", "Fever", "Covid"]


def clinic_diagnosis(dname, p, d):
    if dname == "Cardiology":
        return "Hypertension"
    if dname == "Oncology":
        return "Cancer"
    if dname == "Orthopedics":
        return "Fracture"
    if dname == "Neurology":
        return "Migraine"
    if dname == "Surgery":
        return pick(["Fracture", "Cancer"], [0.55, 0.45])
    if dname == "Pediatrics":
        return pick(["Asthma", "Fever"], [0.55, 0.45])
    if p["chronic"]["diabetes"] and rng.random() < 0.6:
        return "Diabetes"
    winter = MONTH_WEIGHT[d.month] >= 1.05
    opts = ["Diabetes", "Hypertension", "Asthma", "Fever", "Covid"]
    wts = np.array([1.5, 1.0, 1.0, 1.4, 1.2]) * np.array([1, 1, 1.6, 1.6, 1.8] if winter else [1] * 5)
    return pick(opts, wts / wts.sum())


def emergency_diagnosis(p, d):
    winter = MONTH_WEIGHT[d.month] >= 1.05
    opts = ["Fever", "Covid", "Asthma", "Fracture", "Hypertension", "Diabetes", "Migraine", "Cancer"]
    w = np.array([1.3, 1.1, 0.9, 1.4, 1.0, 0.8, 0.7, 0.4])
    if winter:
        w[:3] *= 1.8
    if p["child"]:
        w *= np.array([2.0, 0.5, 2.0, 1.2, 0.0, 0.1, 0.3, 0.05])
    if p["senior"]:
        w *= np.array([0.8, 1.6, 0.8, 1.5, 1.8, 1.4, 0.5, 2.0])
    c = p["chronic"]
    if c["asthma"]:
        w[2] *= 3
    if c["diabetes"]:
        w[5] *= 3
    if c["hypertension"]:
        w[4] *= 2.5
    if c["cancer"]:
        w[7] *= 6
    return pick(opts, w / w.sum())


def route(p, diagnosis):
    """Department for an emergency admission (ICU for severe Covid)."""
    home = p["home"]
    if diagnosis == "Covid" and rng.random() < 0.15:
        name = "ICU"
    elif diagnosis in ("Asthma", "Fever") and p["child"]:
        name = "Pediatrics"
    else:
        name = DIAG_DEPT.get(diagnosis, "General Medicine")
    if (home, name) in DEPT_AT:
        return DEPT_AT[(home, name)]
    if name in ("Pediatrics", "Neurology") or rng.random() < 0.4:
        return DEPT_AT[(home, "General Medicine")]
    return DEPT_AT[(pick(HOSPITALS_WITH[name]), name)]


def draw_los(diagnosis, dname, p, admit):
    mean = ICU_LOS_MEAN if dname == "ICU" else LOS_MEAN[diagnosis]
    los = 1 + rng.poisson(max(mean - 1, 0.2))
    if p["senior"]:
        los = int(round(los * 1.25))
    return int(clip(los, 1, (EXTRACT - timedelta(1) - admit).days))


def ward_for(p, dname):
    if dname == "ICU":
        return "ICU"
    if p["provider"] in PRIVATE_INSURERS:
        return pick(["Private", "Semi", "General"], [0.40, 0.35, 0.25])
    if p["provider"] == "Self-Pay":
        return pick(["Private", "Semi", "General"], [0.10, 0.25, 0.65])
    return pick(["Private", "Semi", "General"], [0.15, 0.35, 0.50])


admissions = []
completed = [r for r in appointments if r["Status"] == "Completed"
             and DEPT_NAME[DOC_DEPT[r["DoctorID"]]] in ADMIT_FROM_CLINIC]
exp_regular = sum(ADMIT_FROM_CLINIC[DEPT_NAME[DOC_DEPT[r["DoctorID"]]]] for r in completed)
scale = TARGET_REGULAR_ADMISSIONS / exp_regular
for r in completed:
    dname = DEPT_NAME[DOC_DEPT[r["DoctorID"]]]
    if rng.random() < ADMIT_FROM_CLINIC[dname] * scale:
        admit = r["Date"] + timedelta(int(rng.integers(0, 15)))
        if admit > END:
            continue
        p = P[r["PatientID"]]
        admissions.append({"PatientID": r["PatientID"], "DepartmentID": DOC_DEPT[r["DoctorID"]],
                           "DoctorID": r["DoctorID"], "Admit": admit, "Type": "Regular",
                           "Diagnosis": clinic_diagnosis(dname, p, admit)})

risk = np.array([(2.0 if P[i]["senior"] else 1.0) * (1 + 0.6 * sum(P[i]["chronic"].values()))
                 for i in P])
for pid in rng.choice(list(P), size=TARGET_EMERGENCY_ADMISSIONS, p=risk / risk.sum()):
    p = P[int(pid)]
    admit = seasonal_date()
    diagnosis = emergency_diagnosis(p, admit)
    did = route(p, diagnosis)
    admissions.append({"PatientID": int(pid), "DepartmentID": did, "DoctorID": pick(DOCS_IN[did]),
                       "Admit": admit, "Type": "Emergency", "Diagnosis": diagnosis})

for a in admissions:
    p = P[a["PatientID"]]
    a["LOS"] = draw_los(a["Diagnosis"], DEPT_NAME[a["DepartmentID"]], p, a["Admit"])

# 30-day readmissions for chronic / severe conditions
readmits = []
for a in admissions:
    p = P[a["PatientID"]]
    if a["Diagnosis"] in ("Cancer", "Diabetes", "Hypertension", "Covid", "Asthma") and \
            rng.random() < (0.18 if p["senior"] else 0.11):
        admit = a["Admit"] + timedelta(a["LOS"] + int(rng.integers(2, 31)))
        if admit <= END:
            b = {"PatientID": a["PatientID"], "DepartmentID": a["DepartmentID"],
                 "DoctorID": a["DoctorID"], "Admit": admit, "Type": "Emergency",
                 "Diagnosis": a["Diagnosis"]}
            b["LOS"] = draw_los(b["Diagnosis"], DEPT_NAME[b["DepartmentID"]], p, admit)
            readmits.append(b)
admissions.extend(readmits)
admissions.sort(key=lambda a: (a["Admit"], a["PatientID"]))

bed_book = {}   # (hospital, bed) -> list of (start, end)
for i, a in enumerate(admissions):
    p = P[a["PatientID"]]
    hid = DEPT_HOSP[a["DepartmentID"]]
    a["AdmissionID"] = i + 1
    a["HospitalID"] = hid
    a["Discharge"] = a["Admit"] + timedelta(a["LOS"])
    a["Ward"] = ward_for(p, DEPT_NAME[a["DepartmentID"]])
    a["Status"] = "Transferred" if rng.random() < 0.03 else "Discharged"
    for _ in range(500):
        bed = int(rng.integers(1, H[hid]["beds"] + 1))
        stays = bed_book.setdefault((hid, bed), [])
        if all(a["Discharge"] <= s or a["Admit"] >= e for s, e in stays):
            stays.append((a["Admit"], a["Discharge"]))
            a["Bed"] = bed
            break

admissions_df = pd.DataFrame([{
    "AdmissionID": a["AdmissionID"], "PatientID": a["PatientID"], "HospitalID": a["HospitalID"],
    "DepartmentID": a["DepartmentID"], "DoctorID": a["DoctorID"], "AdmissionDate": dt(a["Admit"]),
    "DischargeDate": dt(a["Discharge"]), "Diagnosis": a["Diagnosis"], "BedNumber": a["Bed"],
    "Ward": a["Ward"], "AdmissionType": a["Type"], "Status": a["Status"], "LengthOfStay": a["LOS"],
} for a in admissions])

# =============================================================================
# 7. Medicines, 8. Lab tests, 9. Prescriptions
# =============================================================================
med_rows = []
for m in range(1, 31):
    cat = pick(["Tablet", "Syrup", "Injection"], [0.45, 0.25, 0.30])
    price = {"Tablet": rng.uniform(0.5, 4), "Syrup": rng.uniform(6, 18),
             "Injection": rng.uniform(20, 120)}[cat]
    med_rows.append({"MedicineID": m, "MedicineName": f"Medicine {m}", "Category": cat,
                     "Manufacturer": pick(["Abc Pharma", "Medix Labs", "Novagen", "Curewell"]),
                     "UnitPrice": round(price, 2), "StockQuantity": int(rng.integers(50, 1000))})
medicines = pd.DataFrame(med_rows)
MEDS_BY_CAT = {c: medicines.loc[medicines.Category == c, "MedicineID"].tolist()
               for c in ["Tablet", "Syrup", "Injection"]}
PRICE = dict(zip(medicines.MedicineID, medicines.UnitPrice))

TESTS_FOR_DIAG = {"Cancer": ["CT", "MRI", "CBC"], "Fracture": ["CT", "MRI"],
                  "Migraine": ["MRI", "CT"], "Diabetes": ["Blood Sugar", "CBC"],
                  "Covid": ["CBC", "CT"], "Fever": ["CBC"], "Asthma": ["CBC"],
                  "Hypertension": ["Blood Sugar", "CBC"]}
TESTS_FOR_DEPT = {"Oncology": (["CT", "MRI", "CBC"], 0.5), "Neurology": (["MRI", "CT"], 0.4),
                  "Orthopedics": (["CT", "MRI"], 0.35), "Cardiology": (["Blood Sugar", "CBC"], 0.3),
                  "General Medicine": (["CBC", "Blood Sugar"], 0.3), "Emergency": (["CBC", "CT"], 0.35),
                  "Pediatrics": (["CBC"], 0.15), "Surgery": (["CT", "CBC"], 0.3),
                  "ENT": (["CBC"], 0.05), "Dermatology": (["CBC"], 0.05)}


def lab(pid, doc, test, d, inpatient, diagnosis=None):
    lo, hi, base = LAB_TESTS[test]
    prob = base + (0.15 if inpatient else 0)
    if test == "Blood Sugar" and (P[pid]["chronic"]["diabetes"] or diagnosis == "Diabetes"):
        prob = 0.70
    if test in ("CT", "MRI") and diagnosis == "Cancer":
        prob = 0.70
    abnormal = rng.random() < prob
    return {"PatientID": pid, "DoctorID": doc, "TestName": test, "Date": d,
            "Result": "Abnormal" if abnormal else "Normal", "Cost": int(rng.integers(lo, hi + 1)),
            "IsAbnormalResult": "TRUE" if abnormal else "FALSE"}


def rx(pid, doc, d, days, inpatient):
    cat = pick(["Tablet", "Syrup", "Injection"], [0.35, 0.15, 0.50] if inpatient else [0.70, 0.20, 0.10])
    return {"PatientID": pid, "DoctorID": doc, "MedicineID": pick(MEDS_BY_CAT[cat]),
            "Quantity": int(rng.integers(1, 4)), "Days": days, "Date": d}


labs, rxs = [], []
adm_labs, adm_rx = {}, {}
for a in admissions:
    tests = TESTS_FOR_DIAG[a["Diagnosis"]]
    for _ in range(min(4, 1 + rng.poisson(0.8))):
        d = a["Admit"] + timedelta(int(rng.integers(0, a["LOS"])))
        t = lab(a["PatientID"], a["DoctorID"], pick(tests), d, True, a["Diagnosis"])
        labs.append(t)
        adm_labs[a["AdmissionID"]] = adm_labs.get(a["AdmissionID"], 0) + t["Cost"]
    for _ in range(min(5, 2 + rng.poisson(1))):
        d = a["Admit"] + timedelta(int(rng.integers(0, a["LOS"])))
        r = rx(a["PatientID"], a["DoctorID"], d, int(rng.integers(1, a["LOS"] + 1)), True)
        rxs.append(r)
        adm_rx[a["AdmissionID"]] = adm_rx.get(a["AdmissionID"], 0) + r["Quantity"] * r["Days"] * PRICE[r["MedicineID"]]

for r in appointments:
    if r["Status"] != "Completed":
        continue
    dname = DEPT_NAME[DOC_DEPT[r["DoctorID"]]]
    tests, prob = TESTS_FOR_DEPT[dname]
    if rng.random() < prob:
        labs.append(lab(r["PatientID"], r["DoctorID"], pick(tests), r["Date"], False))
    if rng.random() < 0.55:
        chronic = any(P[r["PatientID"]]["chronic"].values()) and r["VisitType"] == "Follow-Up"
        for _ in range(1 + int(rng.random() < 0.3)):
            rxs.append(rx(r["PatientID"], r["DoctorID"], r["Date"],
                          30 if chronic else int(rng.integers(5, 15)), False))

labs.sort(key=lambda t: (t["Date"], t["PatientID"]))
labtests = pd.DataFrame([{"TestID": i + 1, "PatientID": t["PatientID"], "DoctorID": t["DoctorID"],
                          "TestName": t["TestName"], "TestDate": dt(t["Date"]), "Result": t["Result"],
                          "Cost": t["Cost"], "IsAbnormalResult": t["IsAbnormalResult"]}
                         for i, t in enumerate(labs)])
rxs.sort(key=lambda r: (r["Date"], r["PatientID"]))
prescriptions = pd.DataFrame([{"PrescriptionID": i + 1, "PatientID": r["PatientID"],
                               "DoctorID": r["DoctorID"], "MedicineID": r["MedicineID"],
                               "Quantity": r["Quantity"], "Days": r["Days"],
                               "PrescriptionDate": dt(r["Date"])} for i, r in enumerate(rxs)])

# =============================================================================
# 10. Billing (one bill per admission; charges built from the stay itself)
# =============================================================================
bill_rows = []
for a in admissions:
    p = P[a["PatientID"]]
    hid, los, dname = a["HospitalID"], a["LOS"], DEPT_NAME[a["DepartmentID"]]
    f = H[hid]["price"]
    consult = round((200 + 120 * los) * f)
    room = round(WARD_DAILY_RATE[a["Ward"]] * los * f)
    medicine = round(adm_rx.get(a["AdmissionID"], 0))
    lab_charge = adm_labs.get(a["AdmissionID"], 0)
    surgery = 0
    if a["Diagnosis"] == "Fracture" and rng.random() < 0.7:
        surgery = int(rng.integers(6_000, 18_001) * f)
    elif a["Diagnosis"] == "Cancer" and rng.random() < 0.4:
        surgery = int(rng.integers(12_000, 35_001) * f)
    elif dname == "Surgery" and surgery == 0:
        surgery = int(rng.integers(4_000, 12_001) * f)
    other = int(rng.integers(50, 501))
    gross = consult + room + medicine + lab_charge + surgery + other
    if p["provider"] == "Self-Pay":
        discount = round(gross * rng.uniform(0.10, 0.25)) if rng.random() < 0.6 else 0
        method = pick(["Card", "Cash", "Bank Transfer"], [0.5, 0.2, 0.3])
    else:
        discount = round(gross * rng.uniform(0.02, 0.05)) if rng.random() < 0.05 else 0
        method = "Insurance" if rng.random() < 0.9 else "Card"
    gst = 0   # column kept from source schema; no sales tax on US hospital care
    age_days = (EXTRACT - a["Discharge"]).days
    if p["provider"] == "Self-Pay":
        pend = 0.80 if age_days <= 30 else 0.50 if age_days <= 90 else 0.20
    else:
        pend = 0.75 if age_days <= 30 else 0.35 if age_days <= 90 else 0.08
    bill_rows.append({
        "BillID": a["AdmissionID"], "PatientID": a["PatientID"], "AdmissionID": a["AdmissionID"],
        "ConsultationCharge": consult, "RoomCharge": room, "MedicineCharge": medicine,
        "LabCharge": lab_charge, "SurgeryCharge": surgery, "OtherCharge": other,
        "Discount": discount, "GST": gst, "TotalAmount": round(gross - discount + gst, 2),
        "PaymentMethod": method, "PaymentStatus": "Pending" if rng.random() < pend else "Paid",
    })
billing = pd.DataFrame(bill_rows)

# =============================================================================
# Write (same file names as the original cleaned CSVs)
# =============================================================================
out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("Cleaned CSV Final data")
out.mkdir(parents=True, exist_ok=True)
files = {"Hospital_Cleaned.csv": hospitals, "Department_Cleaned.csv": departments,
         "Doctors_Cleaned.csv": doctors, "Doctor_Schedule_Cleaned.csv": schedule,
         "Patients_Cleaned.csv": patients, "Medicines_Cleaned.csv": medicines,
         "Admissions_Cleaned.csv": admissions_df, "Appointments_Cleaned.csv": appointments_df,
         "LabTests_Cleaned.csv": labtests, "Prescriptions_Cleaned.csv": prescriptions,
         "Bills_Cleaned.csv": billing}
for name, df in files.items():
    df.to_csv(out / name, index=False, lineterminator="\n")
    print(f"{name:32s} {len(df):>6,} rows")
