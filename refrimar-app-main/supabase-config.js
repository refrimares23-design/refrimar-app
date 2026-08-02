// ============================================================
// CONFIGURACIÓN DE SUPABASE — REFRIMAR OS
// ------------------------------------------------------------
// 1. Ve a https://supabase.com → tu proyecto → Settings → API
// 2. Copia "Project URL" y pégalo abajo en SUPABASE_URL
// 3. Copia la clave "anon public" y pégala en SUPABASE_ANON_KEY
// 4. Guarda este archivo. Los 3 HTML (facturacion, inventario,
//    reportes) lo cargan automáticamente.
// ============================================================
const SUPABASE_URL = "https://hjecifftqidqeswcpvwt.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhqZWNpZmZ0cWlkcWVzd2Nwdnd0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODUxMDE0NzAsImV4cCI6MjEwMDY3NzQ3MH0.X0pqSe-CVjDgEVO2Cgd89pucXs-cfC7MbJIlx4hfKGM";

const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
