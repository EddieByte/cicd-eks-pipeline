# SonarQube Deployment (PostgreSQL Backend)

## Infrastructure Details
- **Application:** SonarQube  
- **Database:** PostgreSQL  
- **Host:** AWS EC2 (Ubuntu)  
- **Access Method:** SSH + psql  

---

## Issue 8 — SonarQube UI Login Failure (Forgotten Credentials)

- **Error:** Unable to log into SonarQube UI (authentication failure).
- **Root Cause:** Forgotten admin password. SonarQube stores passwords as hashed values in the database, making retrieval impossible.
- **Investigation Steps:**
  1. Connected to EC2 via SSH.
  2. Accessed PostgreSQL:
     ```bash
     sudo -i -u postgres
     psql
     ```
  3. Listed databases: `\l`
  4. Connected to SonarQube database: `\c sonarqube`
  5. Verified admin user existence: `SELECT login FROM users;`

- **Fix:** Password was successfully recalled using contextual memory (username association), avoiding the need for a manual database reset.
- **Fallback Fix (Manual Reset):** If recovery had failed, the following SQL would reset the admin password to `admin`:
  ```sql
  UPDATE users 
  SET crypted_password = '$2a$10$wJ2Yl7G6GkZZgwyU0YJI0uGx1YF8Y6Vd0lR5uR5T2F1F0y5k1Z5yK',
      salt = '100000'
  WHERE login = 'admin';