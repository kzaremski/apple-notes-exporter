module com.zaremski.applenotesexporter {
    requires javafx.controls;
    requires javafx.fxml;


    opens com.zaremski.applenotesexporter to javafx.fxml;
    exports com.zaremski.applenotesexporter;
}